import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:asr/asr.dart';
import 'package:asr_server/asr_server.dart';
import 'package:test/test.dart';

class Controlled implements TranscribeService {
  int calls = 0;
  int active = 0;
  String? upload;
  final started = Completer<void>();
  @override
  Future<TranscribeOutcome> run(
      {required List<String> audioPaths,
      required AsrLanguage language,
      SubtitleFormat format = SubtitleFormat.srt,
      void Function(TranscribeProgress)? onProgress,
      TranscribeCancellation? cancellation}) async {
    calls++;
    active++;
    upload = audioPaths.single;
    try {
      if (calls == 1) {
        final gate = Completer<void>();
        final detach = cancellation!.listen(() => gate.complete());
        started.complete();
        try {
          await gate.future;
          cancellation.throwIfCancelled();
        } finally {
          detach();
        }
      }
      return const TranscribeOutcome(
          text: 'ok', cues: [], elapsed: Duration.zero, audioMs: 100);
    } finally {
      active--;
    }
  }
}

Future<Map<String, dynamic>> jsonRequest(
    HttpClient client, Uri base, String path,
    {String? token}) async {
  final request = await client.postUrl(base.resolve(path));
  if (token != null) request.headers.set('Authorization', 'Bearer $token');
  final response = await request.close();
  final body =
      jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
  return {...body, 'http': response.statusCode};
}

Future<List<Map<String, dynamic>>> submit(
    HttpClient client, Uri base, String id,
    {Completer<void>? queued}) async {
  final request =
      await client.postUrl(base.resolve('v1/transcribe?language=ja&jobId=$id'));
  request.add([1, 2, 3]);
  final response = await request.close();
  final rows = <Map<String, dynamic>>[];
  await for (final line
      in response.transform(utf8.decoder).transform(const LineSplitter())) {
    final row = jsonDecode(line) as Map<String, dynamic>;
    rows.add(row);
    if (row['phase'] == 'queued' && queued != null && !queued.isCompleted) {
      queued.complete();
    }
  }
  return rows;
}

void main() {
  test('active cancellation acknowledges cleanup and next request can run',
      () async {
    final service = Controlled();
    final server =
        AsrServer(runner: service, registry: AsrModelRegistry.builtin());
    final base = await server.start(port: 0);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.stop();
    });
    final id = (await jsonRequest(client, base, 'v1/jobs'))['jobId'] as String;
    final stream = submit(client, base, id);
    await service.started.future;
    final path = service.upload!;
    final reply = await jsonRequest(client, base, 'v1/jobs/$id/cancel');
    expect(reply['status'], 'cancelled');
    expect(service.active, 0);
    expect(File(path).existsSync(), false);
    expect((await stream).last['phase'], 'cancelled');
    final next =
        (await jsonRequest(client, base, 'v1/jobs'))['jobId'] as String;
    expect((await submit(client, base, next)).last['phase'], 'result');
  });
  test('queued cancellation does not occupy or release another request slot',
      () async {
    final service = Controlled();
    final server =
        AsrServer(runner: service, registry: AsrModelRegistry.builtin());
    final base = await server.start(port: 0);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.stop();
    });
    final first =
        (await jsonRequest(client, base, 'v1/jobs'))['jobId'] as String;
    final firstStream = submit(client, base, first);
    await service.started.future;
    final second =
        (await jsonRequest(client, base, 'v1/jobs'))['jobId'] as String;
    final queued = Completer<void>();
    final secondStream = submit(client, base, second, queued: queued);
    await queued.future;
    await jsonRequest(client, base, 'v1/jobs/$second/cancel');
    expect((await secondStream).last['phase'], 'cancelled');
    expect(service.calls, 1);
    expect(service.active, 1);
    final third =
        (await jsonRequest(client, base, 'v1/jobs'))['jobId'] as String;
    final thirdStream = submit(client, base, third);
    await jsonRequest(client, base, 'v1/jobs/$first/cancel');
    await firstStream;
    expect((await thirdStream).last['phase'], 'result');
    expect(service.calls, 2);
  });
  test('reservation cancel is idempotent and protected by server token',
      () async {
    final server = AsrServer(
        runner: Controlled(),
        registry: AsrModelRegistry.builtin(),
        token: 'secret');
    final base = await server.start(port: 0);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.stop();
    });
    expect((await jsonRequest(client, base, 'v1/jobs'))['http'], 401);
    final id =
        (await jsonRequest(client, base, 'v1/jobs', token: 'secret'))['jobId'];
    expect(
        (await jsonRequest(client, base, 'v1/jobs/$id/cancel'))['http'], 401);
    expect(
        (await jsonRequest(client, base, 'v1/jobs/$id/cancel',
            token: 'secret'))['status'],
        'cancelled');
    expect(
        (await jsonRequest(client, base, 'v1/jobs/$id/cancel',
            token: 'secret'))['status'],
        'finished');
  });
}
