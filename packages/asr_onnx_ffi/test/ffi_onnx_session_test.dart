@Tags(<String>['ort'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:asr_core/asr_core.dart';
import 'package:asr_onnx_ffi/asr_onnx_ffi.dart';
import 'package:test/test.dart';

/// 这组用例要真的 onnxruntime 动态库。
///
/// 库不在就整组 skip 而不是红：本包的价值全在「真跑起来」，用 mock 替掉 ORT 等于
/// 什么都没测。取库方式见 README（`ASR_ONNXRUNTIME_LIB` 或放在可执行文件旁边）。
String? _skipReason() {
  try {
    OrtRuntime.instance();
    return null;
  } on OrtRuntimeUnavailable catch (error) {
    return '没有可用的 onnxruntime：$error';
  }
}

void main() {
  final String? skip = _skipReason();

  group('FFI 后端', skip: skip, () {
    late FfiOnnxSessionFactory factory;
    const String decoderPath = 'test/fixtures/greedy_tiny_decoder.onnx';
    const List<OnnxExecutionProvider> cpu = <OnnxExecutionProvider>[
      OnnxExecutionProvider.cpu,
    ];

    setUp(() => factory = FfiOnnxSessionFactory());

    test('装得上运行时，版本可读', () {
      expect(OrtRuntime.instance().versionString, matches(RegExp(r'^\d+\.\d+')));
    });

    test('会话报出模型声明的输入 / 输出名与形状（符号维为 -1）', () async {
      final FfiOnnxSession s = await factory.createSession(
        decoderPath,
        providers: cpu,
      ) as FfiOnnxSession;
      addTearDown(s.close);
      expect(s.inputNames, <String>['y']);
      expect(s.outputNames, <String>['decoder_out']);
      expect(s.inputShapes['y'], <int>[-1, 2]);
    });

    test('freeDimensionOverrides 真的把符号维钉住了', () async {
      // 这条是本包最容易「静默失效」的地方：`AddFreeDimensionOverride` 匹配的是
      // ONNX 的 denotation，`...ByName` 匹配的才是 dim_param（这里是 `N`）。调错
      // 那个既不报错也不生效，只是编码器悄悄慢 5~7 倍。所以要断言形状真变了。
      final FfiOnnxSession s = await factory.createSession(
        decoderPath,
        providers: cpu,
        freeDimensionOverrides: const <String, int>{'N': 3},
      ) as FfiOnnxSession;
      addTearDown(s.close);
      expect(s.inputShapes['y'], <int>[3, 2],
          reason: 'override 没生效 —— 多半是调成了 denotation 那个同族函数');
    });

    test('跑一次推理：int64 输入进去，float32 输出回来', () async {
      final OnnxSession s = await factory.createSession(
        decoderPath,
        providers: cpu,
      );
      addTearDown(s.close);
      final Map<String, OnnxTensor> out = await s.run(<String, OnnxTensor>{
        'y': OnnxTensor.int64(Int64List.fromList(<int>[0, 1, 1, 0]),
            <int>[2, 2]),
      });
      final OnnxTensor decoderOut = out['decoder_out']!;
      expect(decoderOut.type, OnnxTensorType.float32);
      expect(decoderOut.shape, <int>[2, 4]);
      expect(decoderOut.floatData, hasLength(8));
      expect(decoderOut.floatData!.every((double v) => v.isFinite), isTrue);
    });

    test('同一会话连跑两次结果一致（输入内存没有被提前释放）', () async {
      // 回归门：`CreateTensorWithDataAsOrtValue` 不拷贝也不拥有 p_data。如果输入
      // 缓冲区在 Run 之前就被回收，第二次跑很可能拿到垃圾而不是崩——所以判据是
      // 「两次相同」而不是「不崩」。
      final OnnxSession s = await factory.createSession(
        decoderPath,
        providers: cpu,
      );
      addTearDown(s.close);
      final Map<String, OnnxTensor> input = <String, OnnxTensor>{
        'y': OnnxTensor.int64(Int64List.fromList(<int>[2, 3]), <int>[1, 2]),
      };
      final Float32List a = (await s.run(input))['decoder_out']!.floatData!;
      final Float32List b = (await s.run(input))['decoder_out']!.floatData!;
      expect(b, a);
    });

    test('喂模型不认得的输入名 → 明确报错，不是让 ORT 抛天书', () async {
      final OnnxSession s = await factory.createSession(
        decoderPath,
        providers: cpu,
      );
      addTearDown(s.close);
      expect(
        () => s.run(<String, OnnxTensor>{
          'nope': OnnxTensor.int64(Int64List.fromList(<int>[0]), <int>[1]),
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('关掉之后再跑 → StateError', () async {
      final OnnxSession s = await factory.createSession(
        decoderPath,
        providers: cpu,
      );
      await s.close();
      await s.close(); // 幂等
      expect(
        () => s.run(const <String, OnnxTensor>{}),
        throwsA(isA<StateError>()),
      );
    });

    test('模型文件不存在 → FileSystemException', () {
      expect(
        () => factory.createSession('does/not/exist.onnx', providers: cpu),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('模型字节损坏 → OrtException（带 ORT 自己的错误串）', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('asr_ort_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final File bad = File('${tmp.path}${Platform.pathSeparator}bad.onnx')
        ..writeAsBytesSync(Uint8List.fromList(<int>[1, 2, 3, 4]));
      await expectLater(
        factory.createSession(bad.path, providers: cpu),
        throwsA(isA<OrtException>()),
      );
    });

    test('请求本机没有的加速 EP → 回退 CPU，且回退原因可观测', () async {
      final Set<OnnxExecutionProvider> available =
          await factory.availableAcceleratedProviders();
      // 本机若真有 DirectML，这条断言的前提不成立，换成断言「没有回退」。
      final bool hasDml = available.contains(OnnxExecutionProvider.directml);
      OnnxProviderResolution? seen;
      final OnnxSession s = await factory.createSession(
        decoderPath,
        providers: const <OnnxExecutionProvider>[
          OnnxExecutionProvider.directml,
          OnnxExecutionProvider.cpu,
        ],
        onProviderResolved: (OnnxProviderResolution r) => seen = r,
      );
      addTearDown(s.close);
      expect(seen, isNotNull, reason: '建成会话后必定回报一次 resolution');
      if (hasDml) {
        expect(seen!.effective, OnnxExecutionProvider.directml);
      } else {
        expect(seen!.effective, OnnxExecutionProvider.cpu);
        expect(seen!.didFallBack, isTrue);
        expect(seen!.fallbackReason, isNotNull);
      }
    });

    test('EP 探测不抛错，且结果是加速 EP 的子集', () async {
      final Set<OnnxExecutionProvider> available =
          await factory.availableAcceleratedProviders();
      expect(available.contains(OnnxExecutionProvider.cpu), isFalse,
          reason: 'CPU 不算加速 EP');
    });

    test('CoreML FP32 output matches CPU across inputs and repeated runs',
        () async {
      if (!Platform.isMacOS ||
          !(await factory.availableAcceleratedProviders())
              .contains(OnnxExecutionProvider.coreml)) {
        markTestSkipped('macOS CoreML runtime required');
        return;
      }
      const path = 'test/fixtures/greedy_tiny_joiner.onnx';
      final baseline = await factory.createSession(path, providers: cpu);
      addTearDown(baseline.close);
      OnnxProviderResolution? resolution;
      final accelerated = await factory.createSession(path,
          providers: [OnnxExecutionProvider.coreml],
          onProviderResolved: (value) => resolution = value,
          freeDimensionOverrides: {'N': 1});
      addTearDown(accelerated.close);
      expect(resolution!.effective, OnnxExecutionProvider.coreml);
      for (final scale in [0.0, 0.5, -1.0]) {
        final inputs = {
          'encoder_out': OnnxTensor.float32(
              Float32List.fromList([scale, scale * 2, scale * 3, scale * 4]),
              [1, 4]),
          'decoder_out': OnnxTensor.float32(
              Float32List.fromList([0.1, 0.2, -0.3, 0.4]), [1, 4]),
        };
        final expected = (await baseline.run(inputs))['logit']!;
        final actual = (await accelerated.run(inputs))['logit']!;
        expect(actual.shape, expected.shape);
        expect(actual.floatData!.every((v) => v.isFinite), isTrue);
        for (var i = 0; i < expected.elementCount; i++) {
          expect(actual.floatData![i], closeTo(expected.floatData![i], 0.005));
        }
      }
    });

    test('显存预算按未知（null）处理，不冒充 0', () async {
      expect(await factory.deviceMemoryBudgetBytes(), isNull);
    });
  });

  group('库路径解析', () {
    test('顺序：环境变量 > 可执行文件同级 > 裸库名', () {
      final List<String> c = OrtRuntime.resolveLibraryCandidates(
        environment: const <String, String>{'ASR_ONNXRUNTIME_LIB': '/tmp/x.dll'},
        executablePath: '/opt/asr/bin/asr',
      );
      expect(c.first, '/tmp/x.dll');
      expect(c[1], contains('bin'));
      expect(c.last, OrtRuntime.defaultLibraryFileName());
    });

    test('没有环境变量时只剩两条候选', () {
      final List<String> c = OrtRuntime.resolveLibraryCandidates(
        environment: const <String, String>{},
        executablePath: '/opt/asr/bin/asr',
      );
      expect(c, hasLength(2));
    });

    test('空白的环境变量值不算数', () {
      final List<String> c = OrtRuntime.resolveLibraryCandidates(
        environment: const <String, String>{'ASR_ONNXRUNTIME_LIB': '   '},
        executablePath: '/opt/asr/bin/asr',
      );
      expect(c, hasLength(2));
    });
  });
}
