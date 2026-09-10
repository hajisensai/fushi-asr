import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr/asr.dart';
import 'package:fushi_asr_server/asr_server.dart';
import 'package:test/test.dart';

const _input = '''1
00:00:01,000 --> 00:00:03,000
今日はいい天気ですね。

2
00:00:04,000 --> 00:00:06,000
明日は図書館で本を読みます。

''';

const _recognized = <SubtitleCue>[
  SubtitleCue(index: 1, startMs: 6000, endMs: 8000, text: '今日はいい天気ですね'),
  SubtitleCue(index: 2, startMs: 9000, endMs: 11000, text: '明日は図書館で本を読みます'),
];

class _Service implements TranscribeService {
  _Service({this.blockFirst = false});

  final bool blockFirst;
  final started = Completer<void>();
  final paths = <String>[];
  int calls = 0;
  int active = 0;

  @override
  Future<TranscribeOutcome> run({
    required List<String> audioPaths,
    required AsrLanguage language,
    required AsrAudioProfile audioProfile,
    SubtitleFormat format = SubtitleFormat.srt,
    void Function(TranscribeProgress)? onProgress,
    TranscribeCancellation? cancellation,
  }) async {
    calls++;
    active++;
    paths.addAll(audioPaths);
    try {
      if (blockFirst && calls == 1) {
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
      onProgress?.call(const TranscribeProgress(
          phase: 'transcribe', processedMs: 12000, totalMs: 12000));
      return TranscribeOutcome(
        text: renderSubtitles(_recognized, format),
        cues: _recognized,
        elapsed: const Duration(milliseconds: 10),
        audioMs: 12000,
        engine: 'test',
      );
    } finally {
      active--;
    }
  }
}

typedef _Part = ({String name, String? filename, List<int> bytes});

_Part _audio() => (name: 'audio', filename: 'voice.wav', bytes: [1, 2, 3]);
_Part _subtitle({String filename = 'captions.srt', String text = _input}) =>
    (name: 'subtitle', filename: filename, bytes: utf8.encode(text));

Future<({AsrServer server, Uri base})> _start(
  _Service service, {
  int maxUploadBytes = 1024 * 1024,
  List<TranscribeBackend>? backends,
}) async {
  final server = AsrServer(
    runner: service,
    registry: AsrModelRegistry.builtin(),
    maxUploadBytes: maxUploadBytes,
    backends: backends,
  );
  final base = await server.start(port: 0);
  addTearDown(server.stop);
  return (server: server, base: base);
}

Future<({int status, List<Map<String, dynamic>> events})> _submit(
  Uri base, {
  List<_Part>? parts,
  String query = 'language=ja&format=srt&filename=voice.wav',
  String? rawContentType,
  List<int>? rawBody,
}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(base.resolve('v1/retime?$query'));
    if (rawContentType != null) {
      request.headers.set(HttpHeaders.contentTypeHeader, rawContentType);
      request.add(rawBody ?? [1, 2, 3]);
    } else {
      const boundary = 'retime-test-boundary';
      request.headers.contentType = ContentType('multipart', 'form-data',
          parameters: {'boundary': boundary});
      for (final part in parts ?? [_audio(), _subtitle()]) {
        final filename =
            part.filename == null ? '' : '; filename="${part.filename}"';
        request.add(utf8.encode('--$boundary\r\n'
            'Content-Disposition: form-data; name="${part.name}"$filename\r\n'
            'Content-Type: application/octet-stream\r\n\r\n'));
        request.add(part.bytes);
        request.add(utf8.encode('\r\n'));
      }
      request.add(utf8.encode('--$boundary--\r\n'));
    }
    final response = await request.close();
    final content = await utf8.decodeStream(response);
    return (
      status: response.statusCode,
      events: [
        for (final line in const LineSplitter().convert(content))
          if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
      ]
    );
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _job(Uri base, String path) async {
  final client = HttpClient();
  try {
    final response = await (await client.postUrl(base.resolve(path))).close();
    return jsonDecode(await utf8.decodeStream(response))
        as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

void main() {
  test(
      'multipart retiming preserves original text and count with corrected timing',
      () async {
    final service = _Service();
    final server = await _start(service);
    final response = await _submit(server.base);
    expect(response.status, HttpStatus.ok);
    expect(
        response.events.map((e) => e['phase']),
        containsAllInOrder(
            ['queued', 'subtitle', 'transcribe', 'retime', 'result']));
    final result = response.events.last;
    final cues = parseSrt(result['text'] as String);
    expect(cues.map((c) => c.text), parseSrt(_input).map((c) => c.text));
    expect(cues.map((c) => c.startMs), [6000, 9000]);
    expect(cues.map((c) => c.endMs), [8000, 11000]);
    expect(result['cueCount'], 2);
    expect(result['rawText'], renderSubtitles(_recognized, SubtitleFormat.srt));
    expect(result['retiming']['inputCues'], 2);
    expect(result['retiming']['matchedCues'], 2);
    expect(result['retiming']['medianShiftMs'], 5000);
    expect(result['subtitleReadMs'], isNonNegative);
    expect(result['retiming']['elapsedMs'], isNonNegative);
    expect(result['audioMs'], 12000);
    expect(service.calls, 1);
    expect(File(service.paths.single).existsSync(), isFalse);
  });

  test('VTT input and requested backend/output format are supported', () async {
    final fallback = _Service();
    final selected = _Service();
    final server = await _start(fallback, backends: [
      TranscribeBackend(
        id: 'selected',
        name: 'Selected engine',
        description: '',
        service: selected,
        languages: ['ja'],
      ),
    ]);
    final response = await _submit(server.base,
        query: 'language=ja&format=vtt&engine=selected',
        parts: [
          _subtitle(
              filename: 'captions.VTT',
              text: renderSubtitles(parseSrt(_input), SubtitleFormat.vtt)),
          _audio(),
        ]);
    final result = response.events.last;
    expect(result['phase'], 'result');
    expect(result['format'], 'vtt');
    expect(result['text'], startsWith('WEBVTT'));
    expect(result['text'], contains('00:00:06.000 --> 00:00:08.000'));
    expect(result['engine'], 'selected');
    expect(result['engineName'], 'Selected engine');
    expect(selected.calls, 1);
    expect(fallback.calls, 0);
  });

  test(
      'missing, duplicate, extra and unnamed file fields fail before inference',
      () async {
    final service = _Service();
    final server = await _start(service);
    for (final parts in <List<_Part>>[
      [],
      [_audio()],
      [_subtitle()],
      [_audio(), _subtitle(), _subtitle()],
      [_audio(), _audio(), _subtitle()],
      [
        _audio(),
        _subtitle(),
        (name: 'epub', filename: 'book.epub', bytes: [1])
      ],
      [
        _audio(),
        (name: 'subtitle', filename: null, bytes: utf8.encode(_input))
      ],
    ]) {
      final response = await _submit(server.base, parts: parts);
      expect(response.status, HttpStatus.badRequest, reason: '$parts');
      expect(response.events.single['error'], isA<String>());
    }
    expect(service.calls, 0);
  });

  test(
      'malformed, unsupported, empty and non-UTF-8 subtitles fail before inference',
      () async {
    final service = _Service();
    final server = await _start(service);
    for (final subtitle in <_Part>[
      _subtitle(text: 'not a subtitle'),
      _subtitle(filename: 'captions.ass'),
      _subtitle(text: ''),
      _subtitle(text: '1\n00:00:03,000 --> 00:00:01,000\n倒序时间\n'),
      (name: 'subtitle', filename: 'captions.srt', bytes: [0xff, 0xfe, 0x80]),
    ]) {
      final response = await _submit(server.base, parts: [_audio(), subtitle]);
      expect(response.status, HttpStatus.badRequest);
      expect(response.events.single['error'], isA<String>());
    }
    expect(service.calls, 0);
  });

  test('retiming requires multipart with a valid boundary', () async {
    final service = _Service();
    final server = await _start(service);
    for (final type in ['audio/wav', 'multipart/form-data']) {
      final response = await _submit(server.base, rawContentType: type);
      expect(response.status, HttpStatus.badRequest);
    }
    final malformed = await _submit(server.base,
        rawContentType: 'multipart/form-data; boundary=broken',
        rawBody: utf8.encode('--broken\r\ninvalid header\r\n'));
    expect(malformed.status, HttpStatus.badRequest);
    expect(malformed.events.single['error'], contains('multipart'));
    final brokenEnding = await _submit(server.base,
        rawContentType: 'multipart/form-data; boundary=broken',
        rawBody: utf8.encode('--broken\r\n'
            'Content-Disposition: form-data; name="audio"; filename="voice.wav"\r\n'
            '\r\naudio bytes\r\n--brokenINVALID'));
    expect(brokenEnding.status, HttpStatus.badRequest);
    expect(brokenEnding.events.single['error'], contains('multipart'));
    expect(service.calls, 0);
  });

  test('subtitle and media upload size limits fail before inference', () async {
    final service = _Service();
    final server = await _start(service, maxUploadBytes: 4);
    final largeSubtitle = await _submit(server.base, parts: [
      _audio(),
      (
        name: 'subtitle',
        filename: 'captions.srt',
        bytes: List<int>.filled(maxSubtitleBytes + 1, 32)
      ),
    ]);
    expect(largeSubtitle.status, HttpStatus.badRequest);
    expect(largeSubtitle.events.single['error'], contains('上限'));
    final largeAudio = await _submit(server.base, parts: [
      (name: 'audio', filename: 'video.mp4', bytes: [1, 2, 3, 4, 5]),
      _subtitle(),
    ]);
    expect(largeAudio.status, HttpStatus.badRequest);
    expect(largeAudio.events.single['error'], contains('上限'));
    expect(service.calls, 0);
  });

  test(
      'retiming validates language, output format and backend before inference',
      () async {
    final service = _Service();
    final server = await _start(service);
    for (final query in [
      'language=unknown',
      'language=ja&format=ass',
      'language=ja&engine=missing',
    ]) {
      final response = await _submit(server.base, query: query);
      expect(response.status, HttpStatus.badRequest);
      expect(response.events.single['error'], isA<String>());
    }
    expect(service.calls, 0);
  });

  test('retiming cancellation releases its resources and the next job runs',
      () async {
    final service = _Service(blockFirst: true);
    final server = await _start(service);
    final id = (await _job(server.base, 'v1/jobs'))['jobId'];
    final response = _submit(server.base, query: 'language=ja&jobId=$id');
    await service.started.future;
    final path = service.paths.single;
    final cancelled = await _job(server.base, 'v1/jobs/$id/cancel');
    expect(cancelled['status'], 'cancelled');
    expect(service.active, 0);
    expect(File(path).existsSync(), isFalse);
    expect((await response).events.last['phase'], 'cancelled');
    expect((await _submit(server.base)).events.last['phase'], 'result');
    expect(service.calls, 2);
  });
}
