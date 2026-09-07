import 'package:fushi_asr_core/asr_core.dart';

/// Per-session macOS diagnostics. Other platforms return caller options intact.
class MacOsSessionTuning {
  const MacOsSessionTuning(this.threads, this.entries);
  final int? threads;
  final Map<String, String> entries;

  static MacOsSessionTuning resolve(
      {required bool isMacOS,
      required Map<String, String> environment,
      required OnnxExecutionProvider provider,
      int? callerThreads}) {
    if (!isMacOS ||
        !{OnnxExecutionProvider.cpu, OnnxExecutionProvider.coreml}
            .contains(provider)) {
      return MacOsSessionTuning(callerThreads, const {});
    }
    int? positive(String key) {
      final raw = environment[key];
      if (raw == null) return null;
      final value = int.tryParse(raw);
      if (value == null || value < 1 || value > 64) {
        throw ArgumentError('$key must be 1..64');
      }
      return value;
    }

    final threads = provider == OnnxExecutionProvider.coreml
        ? positive('ASR_COREML_ENCODER_THREADS') ?? callerThreads
        : callerThreads ?? positive('ASR_MACOS_CPU_THREADS');
    final entries = <String, String>{};
    final spin = environment['ASR_MACOS_ORT_SPINNING'];
    if (spin != null) {
      if (!{'0', '1'}.contains(spin)) {
        throw ArgumentError('ASR_MACOS_ORT_SPINNING must be 0 or 1');
      }
      entries['session.intra_op.allow_spinning'] = spin;
      entries['session.inter_op.allow_spinning'] = spin;
    }
    return MacOsSessionTuning(threads, entries);
  }
}
