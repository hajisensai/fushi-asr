import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asr/asr.dart';
import 'package:asr_server/asr_server.dart';
import 'package:test/test.dart';

/// 假转录器：不碰真模型，只按脚本回报进度与结果。
///
/// 服务端自己的行为（编码、错误路径、鉴权、并发闸门）与推理无关，用真模型测等于
/// 把一条 200 MB 下载和几秒 GPU 时间绑进单元测试，还测不准这些边界。
class _FakeService implements TranscribeService {
  _FakeService({this.text = 'hello', this.error});

  final String text;
  final Object? error;
  int calls = 0;

  @override
  Future<TranscribeOutcome> run({
    required List<String> audioPaths,
    required AsrLanguage language,
    SubtitleFormat format = SubtitleFormat.srt,
    void Function(TranscribeProgress progress)? onProgress,
  }) async {
    calls++;
    onProgress?.call(const TranscribeProgress(
      phase: 'transcribe',
      processedMs: 500,
      totalMs: 1000,
    ));
    final Object? e = error;
    if (e != null) throw e;
    return TranscribeOutcome(
      text: text,
      cues: <SubtitleCue>[
        SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: text),
      ],
      provider: const OnnxProviderResolution(
        requested: <OnnxExecutionProvider>[OnnxExecutionProvider.cpu],
        effective: OnnxExecutionProvider.cpu,
      ),
      elapsed: const Duration(milliseconds: 100),
      audioMs: 1000,
    );
  }
}

Future<({AsrServer server, Uri uri})> _start(
  TranscribeService service, {
  String? token,
  int concurrency = 1,
}) async {
  final AsrServer server = AsrServer(
    runner: service,
    registry: AsrModelRegistry.builtin(),
    token: token,
    concurrency: concurrency,
  );
  // 端口 0：让系统挑一个空闲端口。写死端口会在 Windows 上撞进
  // 「访问权限不允许」的保留区间（实测 8644 就是），也会撞并发跑的其它测试。
  final Uri uri = await server.start(port: 0);
  return (server: server, uri: uri);
}

/// 直接读 NDJSON 流，不经 AsrClient —— 有些用例要断言"客户端之前"的字节。
Future<List<Map<String, Object?>>> _postRaw(
  Uri base,
  List<int> body, {
  String query = 'language=ja',
  String? token,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest req =
        await client.postUrl(base.resolve('v1/transcribe?$query'));
    if (token != null) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    req.add(body);
    final HttpClientResponse res = await req.close();
    final String text = await utf8.decodeStream(res);
    return <Map<String, Object?>>[
      for (final String line in const LineSplitter().convert(text))
        if (line.trim().isNotEmpty)
          jsonDecode(line) as Map<String, Object?>,
    ];
  } finally {
    client.close(force: true);
  }
}

void main() {
  final List<int> audio = utf8.encode('not really audio');

  test('非 ASCII 字幕能原样回传（latin1 回归门）', () async {
    // 回归门：`HttpResponse.write(String)` 的 IOSink 默认编码是 **latin1**，
    // 日文 / 中文字幕会让它抛 `Invalid argument (string)`。而那一抛发生在流式写
    // 开始之后，状态码已经发出去、外层又没关连接，表现出来是「客户端永远等下去」。
    // 判据必须是"拿到的文本逐字相同"，不是"没崩"。
    const String japanese = '今日はいい天気ですね';
    final ({AsrServer server, Uri uri}) s =
        await _start(_FakeService(text: japanese));
    addTearDown(s.server.stop);
    final List<Map<String, Object?>> events = await _postRaw(s.uri, audio);
    final Map<String, Object?> result =
        events.firstWhere((Map<String, Object?> e) => e['phase'] == 'result');
    expect(result['text'], japanese);
    expect(result['cueCount'], 1);
    expect(result['provider'], 'cpu');
  });

  test('进度事件按序先于结果送出', () async {
    final ({AsrServer server, Uri uri}) s = await _start(_FakeService());
    addTearDown(s.server.stop);
    final List<Map<String, Object?>> events = await _postRaw(s.uri, audio);
    final List<String> phases =
        <String>[for (final Map<String, Object?> e in events) '${e['phase']}'];
    expect(phases.first, 'queued');
    expect(phases.last, 'result');
    expect(phases, contains('transcribe'));
  });

  test('转录抛错 → 收到 error 行，且连接会关（不会一直吊着）', () async {
    final ({AsrServer server, Uri uri}) s =
        await _start(_FakeService(error: StateError('模型炸了')));
    addTearDown(s.server.stop);
    // 这里能返回本身就是断言：流关掉了。挂住的话 test 会超时红。
    final List<Map<String, Object?>> events = await _postRaw(s.uri, audio);
    final Map<String, Object?> last = events.last;
    expect(last['phase'], 'error');
    expect('${last["error"]}', contains('模型炸了'));
  });

  test('不认识的语言 → 400，并列出认得的语言', () async {
    final ({AsrServer server, Uri uri}) s = await _start(_FakeService());
    addTearDown(s.server.stop);
    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    final HttpClientRequest req = await client
        .postUrl(s.uri.resolve('v1/transcribe?language=zzz'));
    req.add(audio);
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, HttpStatus.badRequest);
    final Map<String, Object?> json =
        jsonDecode(await utf8.decodeStream(res)) as Map<String, Object?>;
    expect('${json["error"]}', contains('zzz'));
    expect(json['languages'], contains('ja'));
  });

  test('空请求体 → 400', () async {
    final ({AsrServer server, Uri uri}) s = await _start(_FakeService());
    addTearDown(s.server.stop);
    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    final HttpClientRequest req =
        await client.postUrl(s.uri.resolve('v1/transcribe?language=ja'));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, HttpStatus.badRequest);
  });

  test('设了令牌：没带 / 带错 → 401，带对 → 放行', () async {
    final _FakeService fake = _FakeService();
    final ({AsrServer server, Uri uri}) s =
        await _start(fake, token: 'sekrit');
    addTearDown(s.server.stop);

    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    for (final String? t in <String?>[null, 'wrong']) {
      final HttpClientRequest req =
          await client.getUrl(s.uri.resolve('v1/models'));
      if (t != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
      }
      final HttpClientResponse res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, HttpStatus.unauthorized, reason: '令牌 $t');
    }
    final List<Map<String, Object?>> events =
        await _postRaw(s.uri, audio, token: 'sekrit');
    expect(events.last['phase'], 'result');
    expect(fake.calls, 1);
  });

  test('健康检查不需要令牌（不然探活得配密钥）', () async {
    final ({AsrServer server, Uri uri}) s =
        await _start(_FakeService(), token: 'sekrit');
    addTearDown(s.server.stop);
    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    final HttpClientResponse res =
        await (await client.getUrl(s.uri.resolve('v1/health'))).close();
    expect(res.statusCode, HttpStatus.ok);
    await res.drain<void>();
  });

  test('界面是完整 HTML，且不引用任何外部资源', () async {
    final ({AsrServer server, Uri uri}) s = await _start(_FakeService());
    addTearDown(s.server.stop);
    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    final HttpClientResponse res =
        await (await client.getUrl(s.uri)).close();
    final String html = await utf8.decodeStream(res);
    expect(html, startsWith('<!doctype html>'));
    expect(html, contains('生成字幕'), reason: '中文标题也走同一条编码路径');
    // 服务端常跑在内网 / 离线机器上：界面依赖 CDN 就等于在最需要它的场合打不开。
    expect(html, isNot(contains('http://')));
    expect(html.contains('https://'), isFalse);
  });

  test('AsrClient 能跑通一次完整往返', () async {
    final ({AsrServer server, Uri uri}) s =
        await _start(_FakeService(text: '中文字幕'));
    addTearDown(s.server.stop);
    final Directory tmp = Directory.systemTemp.createTempSync('asr_client_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final File f = File('${tmp.path}${Platform.pathSeparator}a.wav')
      ..writeAsBytesSync(audio);
    final AsrClient client = AsrClient(s.uri);
    addTearDown(client.close);
    final List<String> phases = <String>[];
    final String text = await client.transcribeFile(
      f,
      languageTag: 'ja',
      onProgress: (Map<String, Object?> e) => phases.add('${e['phase']}'),
    );
    expect(text, '中文字幕');
    expect(phases, contains('transcribe'));
    expect((await client.models())['languages'], isA<List<Object?>>());
  });

  test('并发闸门：concurrency=1 时第二个请求排队而不是一起跑', () async {
    final _SlowService slow = _SlowService();
    final ({AsrServer server, Uri uri}) s = await _start(slow);
    addTearDown(s.server.stop);
    final Future<List<Map<String, Object?>>> a = _postRaw(s.uri, audio);
    final Future<List<Map<String, Object?>>> b = _postRaw(s.uri, audio);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(slow.concurrentPeak, 1, reason: 'GPU 会话并发建会把显存撑爆');
    slow.release();
    await Future.wait(<Future<List<Map<String, Object?>>>>[a, b]);
    expect(slow.started, 2);
  });
}

/// 会一直等到 [release] 才返回的转录器，用来观察并发闸门。
class _SlowService implements TranscribeService {
  final List<Completer<void>> _gates = <Completer<void>>[];
  int started = 0;
  int _running = 0;
  int concurrentPeak = 0;
  bool _released = false;

  /// 放行已排队的，**并且**让之后进来的直接过。
  ///
  /// 第二个请求此刻还卡在并发闸门里、根本没进 [run]，它的闸门是放行之后才建的。
  /// 只放行「当前已存在的闸门」会让它永远等下去——这个测试就是这么先红过一次的。
  void release() {
    _released = true;
    for (final Completer<void> c in _gates) {
      if (!c.isCompleted) c.complete();
    }
  }

  @override
  Future<TranscribeOutcome> run({
    required List<String> audioPaths,
    required AsrLanguage language,
    SubtitleFormat format = SubtitleFormat.srt,
    void Function(TranscribeProgress progress)? onProgress,
  }) async {
    started++;
    _running++;
    if (_running > concurrentPeak) concurrentPeak = _running;
    final Completer<void> gate = Completer<void>();
    _gates.add(gate);
    if (_released) gate.complete();
    await gate.future;
    _running--;
    return TranscribeOutcome(
      text: 'ok',
      cues: const <SubtitleCue>[],
      provider: const OnnxProviderResolution(
        requested: <OnnxExecutionProvider>[OnnxExecutionProvider.cpu],
        effective: OnnxExecutionProvider.cpu,
      ),
      elapsed: Duration.zero,
      audioMs: 0,
    );
  }
}
