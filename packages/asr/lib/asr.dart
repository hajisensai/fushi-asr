/// 语音识别生成字幕 —— 一个包够用的入口。
///
/// ```dart
/// final outcome = await TranscribeRunner(
///   registry: await AsrModelRegistry.resolve(),
/// ).run(audioPaths: ['a.mp3'], language: AsrLanguage.japanese);
/// print(outcome.text);
/// ```
///
/// 分层：`asr_core`（纯 Dart 算法，不带后端）→ `asr_onnx_ffi`（ONNX Runtime
/// 后端）→ 本包（装配 + 字幕格式）。只要核心或想换后端的，直接依赖下面两层。
library;

export 'package:asr_core/asr_core.dart';
export 'package:asr_onnx_ffi/asr_onnx_ffi.dart';

export 'src/subtitle_format.dart';
export 'src/transcribe_runner.dart';
