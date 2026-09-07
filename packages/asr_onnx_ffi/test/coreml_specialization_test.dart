import 'package:fushi_asr_onnx_ffi/src/coreml_specialization.dart';
import 'package:test/test.dart';

void main() {
  test('unset strategy preserves provider options and existing cache path', () {
    final settings = CoreMlSpecialization.resolve({});
    expect(settings.value, isNull);
    expect(settings.providerOptions, isEmpty);
    expect(settings.cacheSuffix, isEmpty);
  });

  test('both official strategies set the option and isolate their cache', () {
    for (final strategy in ['Default', 'FastPrediction']) {
      final settings =
          CoreMlSpecialization.resolve({'ASR_COREML_SPECIALIZATION': strategy});
      expect(settings.providerOptions, {'SpecializationStrategy': strategy});
      expect(settings.cacheSuffix, '-specialization-$strategy');
    }
    expect(
        CoreMlSpecialization.resolve({'ASR_COREML_SPECIALIZATION': 'Default'})
            .cacheSuffix,
        isNot(CoreMlSpecialization.resolve(
            {'ASR_COREML_SPECIALIZATION': 'FastPrediction'}).cacheSuffix));
  });

  test('rejects invalid, differently cased and unsafe path values', () {
    for (final value in ['', 'default', 'fastprediction', '1', '../other']) {
      expect(
          () => CoreMlSpecialization.resolve(
              {'ASR_COREML_SPECIALIZATION': value}),
          throwsArgumentError);
    }
  });
}
