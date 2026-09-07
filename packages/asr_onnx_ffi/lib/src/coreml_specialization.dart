/// Optional CoreML load/prediction trade-off for diagnostic A/B runs.
///
/// Call only when creating a macOS CoreML session. An absent environment
/// variable preserves both the existing provider options and cache namespace.
/// https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html
class CoreMlSpecialization {
  const CoreMlSpecialization._(this.value);

  final String? value;

  static CoreMlSpecialization resolve(Map<String, String> environment) {
    final value = environment['ASR_COREML_SPECIALIZATION'];
    if (value != null && !{'Default', 'FastPrediction'}.contains(value)) {
      throw ArgumentError(
          'ASR_COREML_SPECIALIZATION must be Default or FastPrediction');
    }
    return CoreMlSpecialization._(value);
  }

  Map<String, String> get providerOptions =>
      value == null ? const {} : {'SpecializationStrategy': value!};

  /// Explicit strategies get their own cache; the unset default remains exactly
  /// where it was, so adding this diagnostic does not invalidate existing cache.
  String get cacheSuffix => value == null ? '' : '-specialization-$value';
}
