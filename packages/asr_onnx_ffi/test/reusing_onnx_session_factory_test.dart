import 'dart:async';
import 'dart:io';
import 'package:asr_core/asr_core.dart';
import 'package:asr_onnx_ffi/asr_onnx_ffi.dart';
import 'package:test/test.dart';

class FakeFactory implements OnnxSessionFactory {
  final sessions = <FakeSession>[];
  bool fallback = false;
  Completer<void>? gate;
  @override
  Future<OnnxSession> createSession(
    String path, {
    required List<OnnxExecutionProvider> providers,
    void Function(OnnxProviderResolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    await gate?.future;
    onProviderResolved?.call(OnnxProviderResolution(
        requested: providers,
        effective: fallback ? OnnxExecutionProvider.cpu : providers.first,
        fallbackReason: fallback ? 'test failure' : null));
    final session = FakeSession();
    sessions.add(session);
    return session;
  }

  @override
  Future<Set<OnnxExecutionProvider>> availableAcceleratedProviders() async =>
      {OnnxExecutionProvider.coreml};
  @override
  Future<int?> deviceMemoryBudgetBytes() async => null;
}

class FakeSession implements OnnxSession {
  int closes = 0;
  @override
  Future<void> close() async {
    closes++;
  }

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async =>
      inputs;
}

void main() {
  late Directory temp;
  late File model;
  late FakeFactory factory;
  late ReusingOnnxSessionFactory pool;
  const cpu = [OnnxExecutionProvider.cpu];
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('asr-session-pool-test-');
    model = await File('${temp.path}/model.onnx').writeAsString('test');
    factory = FakeFactory();
    pool = ReusingOnnxSessionFactory(factory);
  });
  tearDown(() async {
    await pool.close();
    await temp.delete(recursive: true);
  });

  test(
      'reuses released native session, preserves resolution, closes exactly once',
      () async {
    final first = await pool.createSession(model.path, providers: cpu);
    await first.close();
    await first.close();
    expect(factory.sessions.single.closes, 0);
    OnnxProviderResolution? resolved;
    final second = await pool.createSession(model.path,
        providers: cpu, onProviderResolved: (r) => resolved = r);
    expect(resolved!.effective, OnnxExecutionProvider.cpu);
    expect(factory.sessions, hasLength(1));
    expect(() => first.run({}), throwsStateError);
    await second.close();
    await pool.close();
    await pool.close();
    expect(factory.sessions.single.closes, 1);
    await expectLater(
        pool.createSession(model.path, providers: cpu), throwsStateError);
  });

  test(
      'simultaneous borrowers get distinct sessions; clear rejects active leases',
      () async {
    final leases = await Future.wait([
      pool.createSession(model.path, providers: cpu),
      pool.createSession(model.path, providers: cpu),
    ]);
    expect(factory.sessions, hasLength(2));
    await expectLater(pool.clear(), throwsStateError);
    for (final lease in leases) {
      await lease.close();
    }
    await pool.clear();
    expect(factory.sessions.every((s) => s.closes == 1), isTrue);
  });

  test('shape key is sorted; thread/provider/shape changes never reuse',
      () async {
    Future<void> borrow(
        {int threads = 1,
        List<OnnxExecutionProvider> providers = cpu,
        Map<String, int> shapes = const {'N': 2, 'T': 560}}) async {
      final lease = await pool.createSession(model.path,
          providers: providers,
          intraOpNumThreads: threads,
          freeDimensionOverrides: shapes);
      await lease.close();
    }

    await borrow();
    await borrow(shapes: {'T': 560, 'N': 2});
    expect(factory.sessions, hasLength(1));
    await borrow(threads: 2);
    await borrow(providers: [OnnxExecutionProvider.coreml]);
    await borrow(shapes: {'N': 4, 'T': 560});
    expect(factory.sessions, hasLength(4));
  });

  test('changed model file is not reused', () async {
    await (await pool.createSession(model.path, providers: cpu)).close();
    await model.writeAsString('different model');
    await (await pool.createSession(model.path, providers: cpu)).close();
    expect(factory.sessions, hasLength(2));
  });

  test(
      'fallback sessions retire and retry; active fallback still prevents clear',
      () async {
    factory.fallback = true;
    final lease = await pool
        .createSession(model.path, providers: [OnnxExecutionProvider.coreml]);
    await expectLater(pool.clear(), throwsStateError);
    await lease.close();
    expect(factory.sessions.single.closes, 1);
    factory.fallback = false;
    await (await pool.createSession(model.path,
            providers: [OnnxExecutionProvider.coreml]))
        .close();
    expect(factory.sessions, hasLength(2));
  });

  test('clear rejects session creation in flight', () async {
    factory.gate = Completer<void>();
    final loading = pool.createSession(model.path, providers: cpu);
    await expectLater(pool.clear(), throwsStateError);
    factory.gate!.complete();
    await (await loading).close();
  });
}
