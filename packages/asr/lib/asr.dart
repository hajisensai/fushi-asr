/// 语音识别生成字幕 —— 一个包够用的入口。
///
/// ```dart
/// final outcome = await TranscribeRunner(
///   registry: await AsrModelRegistry.resolve(),
/// ).run(audioPaths: ['a.mp3'], language: AsrLanguage.japanese);
/// print(outcome.text);
/// ```
///
/// 分层：`fushi_asr_core`（纯 Dart 算法，不带后端）→ `fushi_asr_onnx_ffi`（ONNX Runtime
/// 后端）→ 本包（装配 + 字幕格式）。只要核心或想换后端的，直接依赖下面两层。
library;

export 'package:fushi_asr_core/asr_core.dart';
export 'package:fushi_asr_onnx_ffi/asr_onnx_ffi.dart';

export 'src/subtitle_format.dart';
export 'src/subtitle_retiming.dart';
export 'src/transcribe_runner.dart';
export 'src/apple_transcribe_runner.dart';
export 'src/epub_alignment.dart';
export 'src/cancellation.dart';
