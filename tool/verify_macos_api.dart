/// Local live-backend regression: cancel native/ONNX work, then EPUB alignment.
/// Usage: dart run tool/verify_macos_api.dart <long-audio> <short-audio> <book.epub>
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 3)
    throw ArgumentError('Expected long audio, short audio, EPUB');
  final base = Uri.parse('http://127.0.0.1:8642/');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  Future<Map<String, dynamic>> postJson(String path) async {
    final response = await (await client.postUrl(base.resolve(path))).close();
    if (response.statusCode != 200)
      throw StateError('HTTP ${response.statusCode}: $path');
    return jsonDecode(await utf8.decodeStream(response))
        as Map<String, dynamic>;
  }

  Future<HttpClientResponse> submit(String engine, String path,
      {String? jobId, String? epub}) async {
    final uri = base.resolve('v1/transcribe').replace(queryParameters: {
      'engine': engine,
      'language': 'ja',
      'filename': File(path).uri.pathSegments.last,
      if (jobId != null) 'jobId': jobId,
    });
    final request = await client.postUrl(uri);
    if (epub == null) {
      await request.addStream(File(path).openRead());
    } else {
      const boundary = 'fushi-macos-api-regression';
      request.headers.contentType = ContentType('multipart', 'form-data',
          parameters: {'boundary': boundary});
      for (final part in [('epub', epub), ('audio', path)]) {
        request.add(utf8.encode(
            '--$boundary\r\nContent-Disposition: form-data; name="${part.$1}"; filename="${File(part.$2).uri.pathSegments.last}"\r\n\r\n'));
        await request.addStream(File(part.$2).openRead());
        request.add([13, 10]);
      }
      request.add(utf8.encode('--$boundary--\r\n'));
    }
    final response = await request.close();
    if (response.statusCode != 200)
      throw StateError('HTTP ${response.statusCode}: $uri');
    return response;
  }

  try {
    for (final engine in ['apple', 'coreml', 'default']) {
      final id = (await postJson('v1/jobs'))['jobId'] as String;
      final response = await submit(engine, args[0], jobId: id);
      var stopped = false;
      var cancelled = false;
      await for (final line in response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 90))) {
        final row = jsonDecode(line) as Map<String, dynamic>;
        if (!stopped && row['phase'] == 'transcribe') {
          stopped = true;
          final clock = Stopwatch()..start();
          final ack = await postJson('v1/jobs/$id/cancel');
          if (ack['status'] != 'cancelled')
            throw StateError('Bad cancel ack: $ack');
          stdout.writeln(jsonEncode(
              {'engine': engine, 'cancel_ack_ms': clock.elapsedMilliseconds}));
        }
        if (row['phase'] == 'cancelled') cancelled = true;
        if (row['error'] != null) throw StateError('$row');
      }
      if (!stopped || !cancelled)
        throw StateError('No cancellation for $engine');
      final fresh = await submit(engine, args[1], epub: args[2]);
      Map<String, dynamic>? result;
      await for (final line in fresh
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 90))) {
        final row = jsonDecode(line) as Map<String, dynamic>;
        if (row['phase'] == 'result') result = row;
        if (row['error'] != null) throw StateError('$row');
      }
      if (result == null) throw StateError('No fresh result for $engine');
      if (result['alignment'] == null ||
          (result['rawText'] as String).isEmpty ||
          (result['cueCount'] as num) <= 0 ||
          result['fellBack'] != false) {
        throw StateError('Invalid fresh aligned result for $engine');
      }
      final expected = {
        'apple': 'apple-speechtranscriber',
        'coreml': 'coreml',
        'default': 'cpu'
      }[engine];
      if (result['provider'] != expected)
        throw StateError('Unexpected provider: ${result['provider']}');
      stdout.writeln(jsonEncode({
        'engine': engine,
        'fresh_epub_result': true,
        'cue_count': result['cueCount'],
        'transcribe_ms': result['transcribeMs'],
        'provider': result['provider']
      }));
    }
  } finally {
    client.close(force: true);
  }
}
