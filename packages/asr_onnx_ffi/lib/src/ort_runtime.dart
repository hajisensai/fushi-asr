/// ONNX Runtime 动态库的装载、`OrtApi` 取用与错误检查。
///
/// 进程内单例：`OrtEnv` 按 ORT 的契约每进程一个就够，而且建它不便宜。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_asr_onnx_ffi/src/ffi/onnxruntime_bindings.dart';

/// 本包生成绑定所依据的头文件版本对应的 API 版本号。
///
/// ORT 的 C ABI 是**严格尾部追加**的（1.22 → 1.29 删除 0 项、顺序改动 0 处），
/// 所以用这个版本号去问一个更新的 runtime 是安全的，拿回来的表前 322 项布局
/// 完全一致。反过来不成立：runtime 比它老会返回 **nullptr**（不是抛错），
/// 那种情况必须当场报出来而不是空指针崩在后面。
const int kOrtApiVersion = 22;

/// ORT 报错。
class OrtException implements Exception {
  OrtException(this.code, this.message);

  /// `OrtErrorCode`（1 = FAIL，2 = INVALID_ARGUMENT，…）。
  final int code;
  final String message;

  @override
  String toString() => 'OrtException($code): $message';
}

/// 装不出运行时（缺 DLL、缺 VC++ Redist、版本太老）。
class OrtRuntimeUnavailable implements Exception {
  OrtRuntimeUnavailable(this.message, {this.attempted = const <String>[]});

  final String message;

  /// 试过的库路径，按序。报错必须带上它——「找不到 onnxruntime」而不说找过哪里，
  /// 用户只能猜。
  final List<String> attempted;

  @override
  String toString() => attempted.isEmpty
      ? 'OrtRuntimeUnavailable: $message'
      : 'OrtRuntimeUnavailable: $message（试过：${attempted.join(" / ")}）';
}

/// 进程内唯一的 ORT 运行时句柄。
class OrtRuntime {
  OrtRuntime._(this.bindings, this.api, this.env, this.libraryPath);

  static OrtRuntime? _instance;

  final OnnxRuntimeBindings bindings;
  final Pointer<OrtApi> api;
  final Pointer<OrtEnv> env;

  /// 实际装上的库路径（诊断用）。
  final String libraryPath;

  /// 取（或首次建）进程内单例。
  ///
  /// [libraryPathOverride] 只给测试与特殊部署；生产走 [resolveLibraryCandidates]。
  static OrtRuntime instance({String? libraryPathOverride}) {
    final OrtRuntime? existing = _instance;
    if (existing != null) return existing;
    return _instance = _open(libraryPathOverride);
  }

  /// 本进程是否已经装上运行时。
  static bool get isLoaded => _instance != null;

  static OrtRuntime _open(String? override) {
    final List<String> candidates = override != null && override.isNotEmpty
        ? <String>[override]
        : resolveLibraryCandidates();
    final List<String> attempted = <String>[];
    DynamicLibrary? lib;
    Object? lastError;
    for (final String candidate in candidates) {
      attempted.add(candidate);
      try {
        lib = DynamicLibrary.open(candidate);
        break;
      } catch (error) {
        lastError = error;
      }
    }
    if (lib == null) {
      throw OrtRuntimeUnavailable(
        'onnxruntime 动态库打不开：$lastError'
        '${Platform.isWindows ? "（Windows 上最常见的原因是缺 Microsoft Visual "
            "C++ Redistributable —— onnxruntime.dll 静态依赖 MSVCP140.dll）" : ""}',
        attempted: attempted,
      );
    }
    final OnnxRuntimeBindings bindings = OnnxRuntimeBindings(lib);
    final Pointer<OrtApiBase> base = bindings.OrtGetApiBase();
    if (base == nullptr) {
      throw OrtRuntimeUnavailable('OrtGetApiBase 返回空', attempted: attempted);
    }
    final Pointer<OrtApi> api =
        base.ref.GetApi.asFunction<Pointer<OrtApi> Function(int)>()(
      kOrtApiVersion,
    );
    if (api == nullptr) {
      // ORT 对版本不支持的回应是 nullptr，不是抛错。不判这一下就会在第一次调用时
      // 空指针崩，堆栈里看不出真正原因。
      final Pointer<Char> version = base.ref.GetVersionString
          .asFunction<Pointer<Char> Function()>()();
      throw OrtRuntimeUnavailable(
        '这份 onnxruntime（${version == nullptr ? "版本未知" : version.cast<Utf8>().toDartString()}）'
        '不支持 API 版本 $kOrtApiVersion，需要 1.22 或更新',
        attempted: attempted,
      );
    }
    final Pointer<Pointer<OrtEnv>> envOut = calloc<Pointer<OrtEnv>>();
    final Pointer<Utf8> logId = 'asr'.toNativeUtf8();
    try {
      final Pointer<OrtStatus> status = api.ref.CreateEnv.asFunction<
          Pointer<OrtStatus> Function(
        int,
        Pointer<Char>,
        Pointer<Pointer<OrtEnv>>,
      )>()(
        OrtLoggingLevel.ORT_LOGGING_LEVEL_WARNING.value,
        logId.cast<Char>(),
        envOut,
      );
      checkOrtStatus(api, status);
      return OrtRuntime._(bindings, api, envOut.value, attempted.last);
    } finally {
      calloc.free(logId);
      calloc.free(envOut);
    }
  }

  /// 按序给出候选库路径。
  ///
  /// 1. `ASR_ONNXRUNTIME_LIB`：显式指定（开发 / 特殊部署，优先级最高）。
  /// 2. 可执行文件同级目录：随包分发的常规落点。
  /// 3. 裸库名：交给系统搜索路径。
  ///
  /// 与 ffmpeg 的解析顺序同范式（环境变量 > 捆绑 > 系统）。
  static List<String> resolveLibraryCandidates({
    Map<String, String>? environment,
    String? executablePath,
  }) {
    final Map<String, String> env = environment ?? Platform.environment;
    final String bare = defaultLibraryFileName();
    final String? override = env['ASR_ONNXRUNTIME_LIB'];
    final String exe = executablePath ?? Platform.resolvedExecutable;
    return <String>[
      if (override != null && override.trim().isNotEmpty) override.trim(),
      p.join(p.dirname(exe), bare),
      bare,
    ];
  }

  /// 各平台的裸库名。
  static String defaultLibraryFileName() {
    if (Platform.isWindows) return 'onnxruntime.dll';
    if (Platform.isMacOS) return 'libonnxruntime.dylib';
    return 'libonnxruntime.so';
  }

  /// 运行时版本串（`1.22.0`）。
  String get versionString {
    final Pointer<OrtApiBase> base = bindings.OrtGetApiBase();
    final Pointer<Char> v =
        base.ref.GetVersionString.asFunction<Pointer<Char> Function()>()();
    return v == nullptr ? 'unknown' : v.cast<Utf8>().toDartString();
  }
}

/// 检查 ORT 调用的返回状态；非空即失败，读出码与消息后**必须** release。
void checkOrtStatus(Pointer<OrtApi> api, Pointer<OrtStatus> status) {
  if (status == nullptr) return;
  final int code = api.ref.GetErrorCode
      .asFunction<int Function(Pointer<OrtStatus>)>()(status);
  final Pointer<Char> message = api.ref.GetErrorMessage
      .asFunction<Pointer<Char> Function(Pointer<OrtStatus>)>()(status);
  final String text =
      message == nullptr ? '(no message)' : message.cast<Utf8>().toDartString();
  api.ref.ReleaseStatus
      .asFunction<void Function(Pointer<OrtStatus>)>()(status);
  throw OrtException(code, text);
}
