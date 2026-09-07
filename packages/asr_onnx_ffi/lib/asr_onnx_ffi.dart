/// `asr_core` 的纯 Dart ONNX Runtime 后端。
///
/// 给没有 Flutter 引擎的宿主用（CLI / 服务端）。装配：
///
/// ```dart
/// final service = AsrTranscriptionService(
///   backend: const AsrIsolateBackend(buildFactory: buildFfiOnnxFactory),
/// );
/// ```
///
/// 动态库解析顺序：`ASR_ONNXRUNTIME_LIB` > 可执行文件同级 > 系统搜索路径。
library;

export 'src/reusing_onnx_session_factory.dart' show ReusingOnnxSessionFactory;

export 'src/ffi_onnx_session.dart' show FfiOnnxSession;
export 'src/ffi_onnx_session_factory.dart'
    show FfiOnnxSessionFactory, buildFfiOnnxFactory;
export 'src/ort_runtime.dart'
    show OrtException, OrtRuntime, OrtRuntimeUnavailable, kOrtApiVersion;
