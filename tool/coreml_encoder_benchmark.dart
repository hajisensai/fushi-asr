// Encoder-only experiment: no audio/job cache, same deterministic input on CPU
// and CoreML. Model load and repeated runs are timed separately.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:asr_core/asr_core.dart';
import 'package:asr_onnx_ffi/asr_onnx_ffi.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) throw ArgumentError('encoder.onnx [--static] [--basic]');
  final fixed = args.contains('--static');
  final staticOnly = args.contains('--static-only');
  final basic = args.contains('--basic');
  const n = 2, t = 560;
  final random = Random(42);
  final inputs = <String, OnnxTensor>{
    'x': OnnxTensor.float32(
        Float32List.fromList(
            List.generate(n * t * 80, (_) => random.nextDouble() * 10 - 5)),
        [n, t, 80]),
    'x_lens': OnnxTensor.int64(Int64List.fromList([t - 100, t]), [n]),
  };
  Map<String, OnnxTensor>? reference;
  final results = <Object>[];
  for (final ep in [OnnxExecutionProvider.cpu, OnnxExecutionProvider.coreml]) {
    final factory = FfiOnnxSessionFactory(coreMlBasicOptimizations: basic,
      coreMlRequireStaticInputShapes: staticOnly);
    final watch = Stopwatch()..start();
    final session = await factory.createSession(args.first,
        providers: [ep],
        intraOpNumThreads: 4,
        freeDimensionOverrides: fixed ? {'N': n, 'T': t} : null);
    final load = watch.elapsedMicroseconds / 1e6;
    final times = <double>[];
    double maxError = 0, sumError2 = 0, sumRef2 = 0;
    try {
      for (var i = 0; i < 4; i++) {
        watch.reset();
        final output = await session.run(inputs);
        times.add(watch.elapsedMicroseconds / 1e6);
        if (ep == OnnxExecutionProvider.cpu) {
          reference = output;
        } else if (i == 0) {
          for (final name in output.keys) {
            final a = reference![name]!;
            final b = output[name]!;
            if (a.shape.join(',') != b.shape.join(','))
              throw StateError('shape mismatch');
            if (a.floatData == null) continue;
            for (var j = 0; j < a.elementCount; j++) {
              final error = (a.floatData![j] - b.floatData![j]).abs();
              if (!error.isFinite) throw StateError('non-finite output');
              maxError = max(maxError, error);
              sumError2 += error * error;
              sumRef2 += a.floatData![j] * a.floatData![j];
            }
          }
        }
      }
    } finally {
      await session.close();
    }
    results.add({
      'provider': ep.name,
      'load_seconds': load,
      'run_seconds': times,
      'max_absolute_error': maxError,
      'relative_l2_error': sqrt(sumError2 / max(sumRef2, 1e-30))
    });
  }
  stdout.writeln(jsonEncode({
    'require_static_input_shapes': staticOnly,
    'static': fixed,
    'basic': basic,
    'shape': [n, t, 80],
    'results': results
  }));
}
