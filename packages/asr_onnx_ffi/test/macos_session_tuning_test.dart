import 'package:asr_core/asr_core.dart';
import 'package:asr_onnx_ffi/src/macos_session_tuning.dart';
import 'package:test/test.dart';

void main() {
  MacOsSessionTuning resolve(
    Map<String, String> env, {
    bool mac = true,
    OnnxExecutionProvider provider = OnnxExecutionProvider.cpu,
    int? threads,
  }) =>
      MacOsSessionTuning.resolve(
          isMacOS: mac,
          environment: env,
          provider: provider,
          callerThreads: threads);

  test('no environment preserves caller settings', () {
    expect(resolve({}).threads, isNull);
    expect(resolve({}, threads: 4).threads, 4);
    expect(resolve({}).entries, isEmpty);
  });
  test('non-macOS ignores even malformed tuning variables', () {
    final settings = resolve(
        {'ASR_MACOS_CPU_THREADS': 'bad', 'ASR_MACOS_ORT_SPINNING': 'bad'},
        mac: false, threads: 3);
    expect(settings.threads, 3);
    expect(settings.entries, isEmpty);
  });
  test('GPU providers keep their original settings', () {
    for (final provider in [
      OnnxExecutionProvider.directml,
      OnnxExecutionProvider.cuda
    ]) {
      final settings = resolve(
          {'ASR_MACOS_CPU_THREADS': 'bad', 'ASR_MACOS_ORT_SPINNING': 'bad'},
          provider: provider, threads: 2);
      expect(settings.threads, 2);
      expect(settings.entries, isEmpty);
    }
  });
  test('CPU limit only replaces unspecified thread count', () {
    expect(resolve({'ASR_MACOS_CPU_THREADS': '4'}).threads, 4);
    expect(resolve({'ASR_MACOS_CPU_THREADS': '4'}, threads: 1).threads, 1);
  });
  test('CoreML encoder override does not affect CPU sessions', () {
    final env = {
      'ASR_COREML_ENCODER_THREADS': '2',
      'ASR_MACOS_CPU_THREADS': '4'
    };
    expect(resolve(env).threads, 4);
    expect(
        resolve(env, provider: OnnxExecutionProvider.coreml, threads: 1)
            .threads,
        2);
  });
  test('spinning setting applies to both thread pools', () {
    for (final spin in ['0', '1']) {
      expect(resolve({'ASR_MACOS_ORT_SPINNING': spin}).entries, {
        'session.intra_op.allow_spinning': spin,
        'session.inter_op.allow_spinning': spin,
      });
    }
  });
  test('invalid explicit settings fail clearly', () {
    expect(resolve({'ASR_MACOS_CPU_THREADS': '1'}).threads, 1);
    expect(resolve({'ASR_MACOS_CPU_THREADS': '64'}).threads, 64);
    for (final value in ['0', '-1', '65', 'abc', '']) {
      expect(
          () => resolve({'ASR_MACOS_CPU_THREADS': value}), throwsArgumentError);
      expect(
          () => resolve({'ASR_COREML_ENCODER_THREADS': value},
              provider: OnnxExecutionProvider.coreml),
          throwsArgumentError);
    }
    expect(
        () => resolve({'ASR_MACOS_ORT_SPINNING': 'true'}), throwsArgumentError);
  });
}
