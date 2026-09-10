import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr/asr.dart';
import 'package:fushi_asr_server/asr_server.dart';
import 'package:test/test.dart';

/// 模型预下载与「会怎么跑」查询（`/v1/models/status`、`/v1/models/pull`）。
///
/// 这两个端点存在的理由是两件此前看不见的事：模型要下多少、这次会不会掉进 CPU。
/// 所以用例盯的也是这两件事在**没有这能力的后端**上不会假装成功。
class _PlainService implements TranscribeService {
  @override
  Future<TranscribeOutcome> run({
    required List<String> audioPaths,
    required AsrLanguage language,
    required AsrAudioProfile audioProfile,
    SubtitleFormat format = SubtitleFormat.srt,
    void Function(TranscribeProgress progress)? onProgress,
    TranscribeCancellation? cancellation,
  }) async =>
      throw UnimplementedError('这个替身只用来测模型端点');
}

/// 带模型能力的替身：能报状态、能「下载」。
class _ProvisioningService extends _PlainService implements ModelProvisioning {
  _ProvisioningService({
    required this.plan,
    this.events = const <ModelDownloadEvent>[],
  });

  final AsrTranscribePlan plan;
  final List<ModelDownloadEvent> events;
  int pulls = 0;

  @override
  Future<AsrTranscribePlan> planFor({required AsrLanguage language}) async =>
      plan;

  @override
  Stream<ModelDownloadEvent> pullModel({
    required AsrLanguage language,
    AsrEncoderVariant? variant,
  }) async* {
    pulls++;
    for (final ModelDownloadEvent e in events) {
      yield e;
    }
  }
}

Future<({AsrServer server, Uri uri})> _start(TranscribeService service) async {
  final AsrServer server = AsrServer(
    runner: service,
    registry: AsrModelRegistry.builtin(),
  );
  final Uri uri = await server.start(port: 0);
  return (server: server, uri: uri);
}

Future<Map<String, Object?>> _getJson(Uri uri) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(uri);
    final HttpClientResponse response = await request.close();
    final String body = await response.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, Object?>;
  } finally {
    client.close(force: true);
  }
}

Future<List<Map<String, Object?>>> _postNdjson(Uri uri) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(uri);
    final HttpClientResponse response = await request.close();
    final String body = await response.transform(utf8.decoder).join();
    return <Map<String, Object?>>[
      for (final String line in body.split('\n'))
        if (line.trim().isNotEmpty)
          jsonDecode(line) as Map<String, Object?>,
    ];
  } finally {
    client.close(force: true);
  }
}

void main() {
  test('没有模型能力的后端报 managed，而不是假装有东西可下', () async {
    final s = await _start(_PlainService());
    addTearDown(() => s.server.stop());

    final Map<String, Object?> status = await _getJson(
      s.uri.resolve('/v1/models/status?language=ja'),
    );
    expect(status['managed'], isTrue);
    expect(status['ready'], isTrue,
        reason: '模型由系统托管时没有"未就绪"这一态，界面据此隐藏下载入口');

    final List<Map<String, Object?>> pulled = await _postNdjson(
      s.uri.resolve('/v1/models/pull?language=ja'),
    );
    expect(pulled, hasLength(1));
    expect(pulled.single['managed'], isTrue);
  });

  test('未知语言回 400，不猜一个默认语言', () async {
    final s = await _start(_PlainService());
    addTearDown(() => s.server.stop());

    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    final HttpClientRequest request = await client
        .getUrl(s.uri.resolve('/v1/models/status?language=not-a-language'));
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, HttpStatus.badRequest);
  });

  test('缺 language 参数同样回 400', () async {
    final s = await _start(_PlainService());
    addTearDown(() => s.server.stop());

    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    final HttpClientRequest request =
        await client.getUrl(s.uri.resolve('/v1/models/status'));
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, HttpStatus.badRequest);
  });

  test('pull 的事件形状与转录流的 download 阶段逐字一致', () async {
    final AsrLanguage ja = AsrModelRegistry.builtin().languages.first;
    final _ProvisioningService service = _ProvisioningService(
      plan: _planFor(ja),
      events: const <ModelDownloadEvent>[
        ModelDownloadEvent(
            fileName: 'encoder.onnx', receivedBytes: 50, totalBytes: 100),
        ModelDownloadEvent(
            fileName: 'encoder.onnx', receivedBytes: 100, totalBytes: 100),
      ],
    );
    final s = await _start(service);
    addTearDown(() => s.server.stop());

    final List<Map<String, Object?>> events = await _postNdjson(
      s.uri.resolve('/v1/models/pull?language=${ja.tag}'),
    );

    expect(service.pulls, 1);
    final List<Map<String, Object?>> downloads = events
        .where((Map<String, Object?> e) => e['phase'] == 'download')
        .toList();
    // 首条是"开始"探针（0/0），随后是逐文件字节进度。
    expect(downloads.length, greaterThanOrEqualTo(3));
    expect(downloads.last['processedMs'], 100);
    expect(downloads.last['totalMs'], 100);
    expect(downloads.last['detail'], 'encoder.onnx');
    expect(events.last['phase'], 'complete',
        reason: '前端据此收尾；缺了它下载会永远显示进行中');
  });
}

/// 造一个"模型没下全"的 plan。字段取自真实类型，不另造 DTO。
AsrTranscribePlan _planFor(AsrLanguage language) => AsrTranscribePlan(
      language: language,
      variant: AsrEncoderVariant.int8,
      expectedProvider: OnnxExecutionProvider.cpu,
      // 「一个字节都没下」：ready=false、已得 0 / 总量 300 MB。
      modelStatus: const AsrModelStatus(
        ready: false,
        diskBytes: 0,
        totalBytes: 300 * 1024 * 1024,
        obtainedBytes: 0,
      ),
    );
