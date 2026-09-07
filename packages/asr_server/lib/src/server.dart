/// HTTP 服务端：转录跑在这里，CLI 与网页都是调用方。
///
/// 设计上的两个刻意选择：
///
/// - **上传走原始请求体，不做 multipart**。`POST /v1/transcribe?language=ja` 的
///   body 就是音频字节。少一个解析器、少一类边界 bug；浏览器侧
///   `fetch(url, {method:'POST', body: file})` 一行就够。
/// - **响应是流式 NDJSON**，一行一个进度事件，最后一行带结果。不用 SSE：SSE 要
///   自己维护事件分帧，而这里一个连接只服务一个任务，NDJSON 已经够用，且 CLI 和
///   浏览器解析同一套。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asr/asr.dart';

import 'package:asr_server/src/web_ui.dart';

/// 转录服务端。
class AsrServer {
  AsrServer({
    required this.runner,
    required this.registry,
    this.token,
    this.concurrency = 1,
    this.maxUploadBytes = 4 * 1024 * 1024 * 1024,
  }) : assert(concurrency >= 1);

  final TranscribeService runner;
  final AsrModelRegistry registry;

  /// 接口令牌；null = 不鉴权（只在绑回环地址时才该这么用）。
  final String? token;

  /// 同时跑几个任务。**默认 1**：GPU 会话并发建很容易把显存撑爆，而显存不够时
  /// ORT 不报错，是溢出到主机内存后吞吐崩塌——那种"变慢了但没坏"最难查。
  final int concurrency;

  /// 单次上传上限。
  final int maxUploadBytes;

  HttpServer? _http;
  int _running = 0;
  final List<Completer<void>> _waiting = <Completer<void>>[];

  /// 起服务，返回实际监听的地址。
  Future<Uri> start({String host = '127.0.0.1', int port = 8642}) async {
    final HttpServer http = await HttpServer.bind(host, port);
    _http = http;
    unawaited(_serve(http));
    return Uri.parse('http://$host:${http.port}/');
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    _http = null;
  }

  Future<void> _serve(HttpServer http) async {
    await for (final HttpRequest request in http) {
      unawaited(_handle(request).catchError((Object error, StackTrace stack) {
        asrLog('请求处理失败 ${request.uri}: $error\n$stack');
      }));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Headers', 'authorization');
    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }
    final String path = request.uri.path;
    try {
      if (path == '/' || path == '/index.html') {
        response.headers.contentType = ContentType.html;
        response.add(utf8.encode(buildWebUi()));
        await response.close();
        return;
      }
      if (path == '/v1/health') {
        await _json(response, <String, Object?>{'ok': true});
        return;
      }
      if (!_authorized(request)) {
        response.statusCode = HttpStatus.unauthorized;
        await _json(response, <String, Object?>{'error': '需要 Bearer 令牌'});
        return;
      }
      if (path == '/v1/models' && request.method == 'GET') {
        await _json(response, <String, Object?>{
          'languages': <Object>[
            for (final AsrLanguage l in registry.languages)
              <String, String>{'tag': l.tag, 'nativeName': l.nativeName},
          ],
          'packs': <Object>[
            for (final AsrModelPack p in registry.packs)
              <String, Object?>{
                'id': p.id,
                'displayName': p.displayName,
                'architecture': p.architecture.name,
                'languages':
                    <String>[for (final AsrLanguage l in p.languages) l.tag],
              },
          ],
        });
        return;
      }
      if (path == '/v1/transcribe' && request.method == 'POST') {
        await _transcribe(request, response);
        return;
      }
      response.statusCode = HttpStatus.notFound;
      await _json(response, <String, Object?>{'error': '没有这个接口：$path'});
    } catch (error) {
      asrLog('请求处理失败 ${request.uri}: $error');
      try {
        response.statusCode = HttpStatus.internalServerError;
        await _json(response, <String, Object?>{'error': '$error'});
      } catch (_) {
        // 响应已经开始写了（流式路径）：状态码改不了，但**必须把连接关掉**。
        // 不关的话客户端会一直等下去——比拿到一个错误码难查得多。
        try {
          await response.close();
        } catch (_) {
          // 连关都失败：底层连接已经没了，没有别的补救。
        }
      }
    }
  }

  bool _authorized(HttpRequest request) {
    final String? expected = token;
    if (expected == null) return true;
    final String? header = request.headers.value(HttpHeaders.authorizationHeader);
    return header == 'Bearer $expected';
  }

  Future<void> _transcribe(HttpRequest request, HttpResponse response) async {
    final String? tag = request.uri.queryParameters['language'];
    final AsrLanguage? language = AsrLanguage.fromTag(tag);
    if (language == null) {
      response.statusCode = HttpStatus.badRequest;
      await _json(response, <String, Object?>{
        'error': '缺 language 或不认识："$tag"',
        'languages': <String>[
          for (final AsrLanguage l in registry.languages) l.tag,
        ],
      });
      return;
    }
    final String formatName =
        request.uri.queryParameters['format'] ?? 'srt';
    final SubtitleFormat? format = SubtitleFormat.fromName(formatName);
    if (format == null) {
      response.statusCode = HttpStatus.badRequest;
      await _json(response, <String, Object?>{'error': '未知格式 $formatName'});
      return;
    }

    final Directory work =
        await Directory.systemTemp.createTemp('asr_upload_');
    final File upload = File('${work.path}${Platform.pathSeparator}'
        '${_safeName(request.uri.queryParameters['filename'])}');
    try {
      int received = 0;
      final IOSink sink = upload.openWrite();
      try {
        await for (final List<int> chunk in request) {
          received += chunk.length;
          if (received > maxUploadBytes) {
            throw const FormatException('上传超过上限');
          }
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      if (received == 0) {
        response.statusCode = HttpStatus.badRequest;
        await _json(response, <String, Object?>{'error': '请求体是空的'});
        return;
      }

      response.statusCode = HttpStatus.ok;
      response.headers.contentType =
          ContentType('application', 'x-ndjson', charset: 'utf-8');
      response.bufferOutput = false;
      // **必须显式编码成 UTF-8 字节**，不能用 `response.write(String)`：
      // `HttpResponse` 的 `IOSink` 默认编码是 **latin1**，只要字幕里有一个非
      // ASCII 字符（日文、中文、带重音的欧洲语言……）就会抛
      // `Invalid argument (string): Contains invalid characters`。而这一抛发生在
      // 流式写开始之后，状态码已经发出去改不了，表现出来就是「连接永远不关」，
      // 客户端一直等——最难查的那种失败。
      void emit(Map<String, Object?> json) {
        response.add(utf8.encode('${jsonEncode(json)}\n'));
      }

      await _acquire();
      try {
        emit(<String, Object?>{'phase': 'queued', 'fraction': 0});
        final TranscribeOutcome outcome = await runner.run(
          audioPaths: <String>[upload.path],
          language: language,
          format: format,
          onProgress: (TranscribeProgress p) => emit(p.toJson()),
        );
        emit(<String, Object?>{
          'phase': 'result',
          'fraction': 1,
          'format': format.name,
          'cueCount': outcome.cues.length,
          'audioMs': outcome.audioMs,
          'elapsedMs': outcome.elapsed.inMilliseconds,
          'provider': outcome.provider.effective.name,
          'fellBack': outcome.provider.didFallBack,
          'text': outcome.text,
        });
      } catch (error) {
        // 已经开始流式写了，改不了状态码，所以错误也走 NDJSON 的最后一行。
        // 客户端的判据必须是「有没有收到 result 行」，不是 HTTP 状态码。
        emit(<String, Object?>{'phase': 'error', 'error': '$error'});
      } finally {
        _release();
      }
      await response.close();
    } finally {
      if (work.existsSync()) {
        try {
          work.deleteSync(recursive: true);
        } on FileSystemException {
          // 转录进程可能还占着；留给系统清临时目录。
        }
      }
    }
  }

  Future<void> _acquire() async {
    if (_running < concurrency) {
      _running++;
      return;
    }
    final Completer<void> waiter = Completer<void>();
    _waiting.add(waiter);
    await waiter.future;
    _running++;
  }

  void _release() {
    _running--;
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    }
  }

  Future<void> _json(HttpResponse response, Map<String, Object?> json) async {
    response.headers.contentType = ContentType.json;
    response.add(utf8.encode(jsonEncode(json)));
    await response.close();
  }
}

/// 上传文件名只用来给 ffmpeg 一个像样的扩展名；一律剥路径分隔符。
///
/// 直接拿用户给的名字拼路径是经典的目录穿越（`../../etc/passwd`）。这里不需要
/// 保留原名，所以最简单的正确做法是只留 basename 里的安全字符。
String _safeName(String? raw) {
  if (raw == null || raw.isEmpty) return 'upload.bin';
  final String base = raw.split(RegExp(r'[\\/]')).last;
  final String cleaned = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'upload.bin';
  return cleaned.length > 120 ? cleaned.substring(cleaned.length - 120) : cleaned;
}
