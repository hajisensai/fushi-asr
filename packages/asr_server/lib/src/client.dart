/// asr 服务端的客户端。
///
/// `asr transcribe --server http://host:port` 走它。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 服务端返回的错误。
class AsrServerException implements Exception {
  AsrServerException(this.message);
  final String message;

  @override
  String toString() => 'AsrServerException: $message';
}

/// 转录服务端客户端。
class AsrClient {
  AsrClient(this.baseUrl, {this.token, HttpClient? httpClient})
      : _client = httpClient ?? HttpClient();

  final Uri baseUrl;
  final String? token;
  final HttpClient _client;

  void close() => _client.close(force: true);

  /// 把 [file] 传上去转录，返回渲染好的字幕文本。
  ///
  /// 判据是**收没收到 `result` 行**，不是 HTTP 状态码：服务端一旦开始流式写就
  /// 改不了状态码了，失败也只能作为最后一行 NDJSON 送回来。
  Future<String> transcribeFile(
    File file, {
    required String languageTag,
    String format = 'srt',
    void Function(Map<String, Object?> event)? onProgress,
  }) async {
    final Uri uri = baseUrl.resolve('v1/transcribe').replace(
      queryParameters: <String, String>{
        'language': languageTag,
        'format': format,
        'filename': file.uri.pathSegments.last,
      },
    );
    final HttpClientRequest request = await _client.postUrl(uri);
    final String? t = token;
    if (t != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
    }
    request.headers.contentType = ContentType.binary;
    request.contentLength = await file.length();
    await request.addStream(file.openRead());
    final HttpClientResponse response = await request.close();

    if (response.statusCode != HttpStatus.ok) {
      final String body = await response.transform(utf8.decoder).join();
      throw AsrServerException('HTTP ${response.statusCode}：$body');
    }

    String? text;
    String? error;
    await for (final String line in response
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final Object? decoded = jsonDecode(line);
      if (decoded is! Map<String, Object?>) continue;
      switch (decoded['phase']) {
        case 'result':
          text = decoded['text'] as String?;
        case 'error':
          error = decoded['error'] as String?;
        default:
          onProgress?.call(decoded);
      }
    }
    if (error != null) throw AsrServerException(error);
    if (text == null) {
      throw AsrServerException('连接结束但没有收到结果（服务端可能被中断了）');
    }
    return text;
  }

  /// 服务端认得哪些语言与模型包。
  Future<Map<String, Object?>> models() async {
    final HttpClientRequest request =
        await _client.getUrl(baseUrl.resolve('v1/models'));
    final String? t = token;
    if (t != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
    }
    final HttpClientResponse response = await request.close();
    final String body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw AsrServerException('HTTP ${response.statusCode}：$body');
    }
    return jsonDecode(body) as Map<String, Object?>;
  }
}
