/// `OnnxSession` 的 dart:ffi 实现。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:asr_core/asr_core.dart';
import 'package:ffi/ffi.dart';

import 'package:asr_onnx_ffi/src/ffi/onnxruntime_bindings.dart';
import 'package:asr_onnx_ffi/src/ort_runtime.dart';

/// 一次 ORT 会话。
///
/// 与插件后端的两点行为差异，都是**更接近真相**的方向：
/// - 输出按 ORT 报的元素类型原样返回（float32 / int64 / int32），不再一律读成
///   float。核心层的 `_lengthAt` 三型都吃，`_floatData` 要的那几个本来就是 float。
/// - 输入零拷贝进 native 内存后直接建张量（`CreateTensorWithDataAsOrtValue` 不
///   拷贝也不拥有 `p_data`），省掉 method channel 的两次序列化。
class FfiOnnxSession implements OnnxSession {
  FfiOnnxSession._(this._runtime, this._session, this._inputNames,
      this._outputNames, this._allocator, this._profiling);

  /// 用模型字节建会话。
  ///
  /// 走 `CreateSessionFromArray`（吃 bytes）而不是 `CreateSession`（吃路径）是
  /// 有意的：路径参数的类型是 `ORTCHAR_T*`，在 Windows 上是 `wchar_t*`、其它平台
  /// 是 `char*`。跨平台生成的绑定只会给出一种，在 Windows 上按 UTF-8 传就是
  /// **静默传一个乱码路径**。吃 bytes 的这条没有这个坑。
  ///
  /// 代价是模型字节要过一次 Dart 堆。ASR 最大的包是 fp32 编码器（约 600 MB），
  /// 建会话本来就要把它读进内存，这一次拷贝在总量里是零头。
  static FfiOnnxSession create(OrtRuntime runtime, Uint8List modelBytes,
      Pointer<OrtSessionOptions> options,
      {bool profiling = false}) {
    final Pointer<OrtApi> api = runtime.api;
    final Pointer<Uint8> buffer = calloc<Uint8>(modelBytes.length);
    final Pointer<Pointer<OrtSession>> sessionOut =
        calloc<Pointer<OrtSession>>();
    try {
      buffer.asTypedList(modelBytes.length).setAll(0, modelBytes);
      checkOrtStatus(
        api,
        api.ref.CreateSessionFromArray.asFunction<
            Pointer<OrtStatus> Function(
          Pointer<OrtEnv>,
          Pointer<Void>,
          int,
          Pointer<OrtSessionOptions>,
          Pointer<Pointer<OrtSession>>,
        )>()(
          runtime.env,
          buffer.cast<Void>(),
          modelBytes.length,
          options,
          sessionOut,
        ),
      );
      final Pointer<OrtSession> session = sessionOut.value;
      final Pointer<OrtAllocator> allocator = _defaultAllocator(api);
      return FfiOnnxSession._(
        runtime,
        session,
        _ioNames(api, session, allocator, inputs: true),
        _ioNames(api, session, allocator, inputs: false),
        allocator,
        profiling,
      );
    } finally {
      calloc.free(buffer);
      calloc.free(sessionOut);
    }
  }

  final OrtRuntime _runtime;
  final Pointer<OrtSession> _session;
  final Pointer<OrtAllocator> _allocator;
  final bool _profiling;

  /// 模型声明的输入 / 输出名，按序。
  final List<String> _inputNames;
  final List<String> _outputNames;

  bool _closed = false;

  List<String> get inputNames => List<String>.unmodifiable(_inputNames);
  List<String> get outputNames => List<String>.unmodifiable(_outputNames);

  /// 每个输入的形状；**符号维（`N` / `T` 这类 dim_param）报 -1**。
  ///
  /// 存在的理由是可验证性：`AddFreeDimensionOverrideByName` 生效与否在跑起来之前
  /// 看不出差别——调成了同族的 `AddFreeDimensionOverride`（匹配 denotation 而不是
  /// dim_param）既不报错也不生效，只是编码器悄悄慢 5~7 倍。有了这个口，「override
  /// 之后这一维真的固定了吗」就能当场断言。
  Map<String, List<int>> get inputShapes {
    final Pointer<OrtApi> api = _runtime.api;
    final Map<String, List<int>> out = <String, List<int>>{};
    for (int i = 0; i < _inputNames.length; i++) {
      final Pointer<Pointer<OrtTypeInfo>> infoOut =
          calloc<Pointer<OrtTypeInfo>>();
      try {
        checkOrtStatus(
          api,
          api.ref.SessionGetInputTypeInfo.asFunction<
              Pointer<OrtStatus> Function(Pointer<OrtSession>, int,
                  Pointer<Pointer<OrtTypeInfo>>)>()(_session, i, infoOut),
        );
        final Pointer<OrtTypeInfo> info = infoOut.value;
        try {
          final Pointer<Pointer<OrtTensorTypeAndShapeInfo>> shapeOut =
              calloc<Pointer<OrtTensorTypeAndShapeInfo>>();
          final Pointer<Size> dimCountOut = calloc<Size>();
          try {
            checkOrtStatus(
              api,
              api.ref.CastTypeInfoToTensorInfo.asFunction<
                  Pointer<OrtStatus> Function(
                      Pointer<OrtTypeInfo>,
                      Pointer<Pointer<OrtTensorTypeAndShapeInfo>>)>()(
                  info, shapeOut),
            );
            final Pointer<OrtTensorTypeAndShapeInfo> shape = shapeOut.value;
            if (shape == nullptr) continue;
            checkOrtStatus(
              api,
              api.ref.GetDimensionsCount.asFunction<
                  Pointer<OrtStatus> Function(
                      Pointer<OrtTensorTypeAndShapeInfo>,
                      Pointer<Size>)>()(shape, dimCountOut),
            );
            final int dimCount = dimCountOut.value;
            final Pointer<Int64> dims = calloc<Int64>(dimCount);
            try {
              checkOrtStatus(
                api,
                api.ref.GetDimensions.asFunction<
                    Pointer<OrtStatus> Function(
                        Pointer<OrtTensorTypeAndShapeInfo>,
                        Pointer<Int64>,
                        int)>()(shape, dims, dimCount),
              );
              out[_inputNames[i]] = <int>[
                for (int d = 0; d < dimCount; d++) dims[d],
              ];
            } finally {
              calloc.free(dims);
            }
            // CastTypeInfoToTensorInfo 给的是 info 内部的视图，**不要单独 release**。
          } finally {
            calloc.free(shapeOut);
            calloc.free(dimCountOut);
          }
        } finally {
          api.ref.ReleaseTypeInfo
              .asFunction<void Function(Pointer<OrtTypeInfo>)>()(info);
        }
      } finally {
        calloc.free(infoOut);
      }
    }
    return out;
  }

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    if (_closed) throw StateError('会话已关闭');
    final Pointer<OrtApi> api = _runtime.api;

    // 只喂模型认得的输入名。多喂一个 ORT 会整体报错，而调用方常常按「全集」组装
    // （贪心 Loop 图与朴素三件套的输入名不完全一样）。
    final List<String> names = <String>[
      for (final String name in _inputNames)
        if (inputs.containsKey(name)) name,
    ];
    final List<String> missing = <String>[
      for (final String name in inputs.keys)
        if (!_inputNames.contains(name)) name,
    ];
    if (missing.isNotEmpty) {
      throw ArgumentError(
        '模型没有这些输入：${missing.join(", ")}（模型声明的是 ${_inputNames.join(", ")}）',
      );
    }

    final _RunArena arena = _RunArena();
    try {
      final Pointer<Pointer<Char>> inputNamePtrs =
          arena.allocCharPtrs(names.length);
      final Pointer<Pointer<OrtValue>> inputValues =
          arena.allocValuePtrs(names.length);
      for (int i = 0; i < names.length; i++) {
        inputNamePtrs[i] = arena.utf8(names[i]);
        inputValues[i] = _createTensor(api, arena, inputs[names[i]]!);
      }
      final Pointer<Pointer<Char>> outputNamePtrs =
          arena.allocCharPtrs(_outputNames.length);
      final Pointer<Pointer<OrtValue>> outputValues =
          arena.allocValuePtrs(_outputNames.length);
      for (int i = 0; i < _outputNames.length; i++) {
        outputNamePtrs[i] = arena.utf8(_outputNames[i]);
        outputValues[i] = nullptr;
      }

      checkOrtStatus(
        api,
        api.ref.Run.asFunction<
            Pointer<OrtStatus> Function(
          Pointer<OrtSession>,
          Pointer<OrtRunOptions>,
          Pointer<Pointer<Char>>,
          Pointer<Pointer<OrtValue>>,
          int,
          Pointer<Pointer<Char>>,
          int,
          Pointer<Pointer<OrtValue>>,
        )>()(
          _session,
          nullptr,
          inputNamePtrs,
          inputValues,
          names.length,
          outputNamePtrs,
          _outputNames.length,
          outputValues,
        ),
      );

      final Map<String, OnnxTensor> out = <String, OnnxTensor>{};
      for (int i = 0; i < _outputNames.length; i++) {
        final Pointer<OrtValue> value = outputValues[i];
        if (value == nullptr) continue;
        try {
          out[_outputNames[i]] = _readTensor(api, value);
        } finally {
          api.ref.ReleaseValue
              .asFunction<void Function(Pointer<OrtValue>)>()(value);
        }
      }
      // 输入张量在读完输出后才释放：ORT 不拥有 p_data，提前放会是 use-after-free。
      for (int i = 0; i < names.length; i++) {
        api.ref.ReleaseValue
            .asFunction<void Function(Pointer<OrtValue>)>()(inputValues[i]);
      }
      return out;
    } finally {
      arena.releaseAll();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      if (_profiling) {
        final api = _runtime.api;
        final out = calloc<Pointer<Char>>();
        try {
          checkOrtStatus(
              api,
              api.ref.SessionEndProfiling.asFunction<
                  Pointer<OrtStatus> Function(
                      Pointer<OrtSession>,
                      Pointer<OrtAllocator>,
                      Pointer<Pointer<Char>>)>()(_session, _allocator, out));
          stderr
              .writeln('ORT profile: ${out.value.cast<Utf8>().toDartString()}');
        } finally {
          if (out.value != nullptr) {
            api.ref.AllocatorFree.asFunction<
                Pointer<OrtStatus> Function(Pointer<OrtAllocator>,
                    Pointer<Void>)>()(_allocator, out.value.cast<Void>());
          }
          calloc.free(out);
        }
      }
    } finally {
      _runtime.api.ref.ReleaseSession
          .asFunction<void Function(Pointer<OrtSession>)>()(_session);
    }
  }

  // --- 内部 ---

  static Pointer<OrtAllocator> _defaultAllocator(Pointer<OrtApi> api) {
    final Pointer<Pointer<OrtAllocator>> out = calloc<Pointer<OrtAllocator>>();
    try {
      checkOrtStatus(
        api,
        api.ref.GetAllocatorWithDefaultOptions.asFunction<
            Pointer<OrtStatus> Function(Pointer<Pointer<OrtAllocator>>)>()(out),
      );
      // 这个 allocator 是 ORT 的进程级单例，**不要 release**。
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  static List<String> _ioNames(
    Pointer<OrtApi> api,
    Pointer<OrtSession> session,
    Pointer<OrtAllocator> allocator, {
    required bool inputs,
  }) {
    final Pointer<Size> countOut = calloc<Size>();
    try {
      checkOrtStatus(
        api,
        inputs
            ? api.ref.SessionGetInputCount.asFunction<
                Pointer<OrtStatus> Function(
                    Pointer<OrtSession>, Pointer<Size>)>()(session, countOut)
            : api.ref.SessionGetOutputCount.asFunction<
                Pointer<OrtStatus> Function(
                    Pointer<OrtSession>, Pointer<Size>)>()(session, countOut),
      );
      final int count = countOut.value;
      final List<String> names = <String>[];
      for (int i = 0; i < count; i++) {
        final Pointer<Pointer<Char>> nameOut = calloc<Pointer<Char>>();
        try {
          checkOrtStatus(
            api,
            inputs
                ? api.ref.SessionGetInputName.asFunction<
                    Pointer<OrtStatus> Function(Pointer<OrtSession>, int,
                        Pointer<OrtAllocator>, Pointer<Pointer<Char>>)>()(
                    session, i, allocator, nameOut)
                : api.ref.SessionGetOutputName.asFunction<
                    Pointer<OrtStatus> Function(Pointer<OrtSession>, int,
                        Pointer<OrtAllocator>, Pointer<Pointer<Char>>)>()(
                    session, i, allocator, nameOut),
          );
          names.add(nameOut.value.cast<Utf8>().toDartString());
          // 名字是 ORT 用 allocator 分配的，**必须**还回去，否则每建一次会话漏一串。
          checkOrtStatus(
            api,
            api.ref.AllocatorFree.asFunction<
                Pointer<OrtStatus> Function(Pointer<OrtAllocator>,
                    Pointer<Void>)>()(allocator, nameOut.value.cast<Void>()),
          );
        } finally {
          calloc.free(nameOut);
        }
      }
      return names;
    } finally {
      calloc.free(countOut);
    }
  }

  static Pointer<OrtValue> _createTensor(
    Pointer<OrtApi> api,
    _RunArena arena,
    OnnxTensor tensor,
  ) {
    final Pointer<Int64> shape = arena.allocInt64(tensor.shape.length);
    for (int i = 0; i < tensor.shape.length; i++) {
      shape[i] = tensor.shape[i];
    }
    final int count = tensor.elementCount;
    final Pointer<Void> data;
    final int byteLength;
    final int elementType;
    switch (tensor.type) {
      case OnnxTensorType.float32:
        final Pointer<Float> buf = arena.allocFloat(count);
        buf.asTypedList(count).setAll(0, tensor.floatData!);
        data = buf.cast<Void>();
        byteLength = count * 4;
        elementType =
            ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT.value;
      case OnnxTensorType.int64:
        final Pointer<Int64> buf = arena.allocInt64(count);
        buf.asTypedList(count).setAll(0, tensor.intData!);
        data = buf.cast<Void>();
        byteLength = count * 8;
        elementType =
            ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64.value;
      case OnnxTensorType.int32:
        final Pointer<Int32> buf = arena.allocInt32(count);
        buf.asTypedList(count).setAll(0, tensor.int32Data!);
        data = buf.cast<Void>();
        byteLength = count * 4;
        elementType =
            ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32.value;
    }
    final Pointer<Pointer<OrtValue>> out = arena.allocValuePtrs(1);
    checkOrtStatus(
      api,
      api.ref.CreateTensorWithDataAsOrtValue.asFunction<
          Pointer<OrtStatus> Function(
        Pointer<OrtMemoryInfo>,
        Pointer<Void>,
        int,
        Pointer<Int64>,
        int,
        int,
        Pointer<Pointer<OrtValue>>,
      )>()(
        arena.cpuMemoryInfo(api),
        data,
        byteLength,
        shape,
        tensor.shape.length,
        elementType,
        out,
      ),
    );
    return out.value;
  }

  static OnnxTensor _readTensor(Pointer<OrtApi> api, Pointer<OrtValue> value) {
    final Pointer<Pointer<OrtTensorTypeAndShapeInfo>> infoOut =
        calloc<Pointer<OrtTensorTypeAndShapeInfo>>();
    try {
      checkOrtStatus(
        api,
        api.ref.GetTensorTypeAndShape.asFunction<
            Pointer<OrtStatus> Function(Pointer<OrtValue>,
                Pointer<Pointer<OrtTensorTypeAndShapeInfo>>)>()(value, infoOut),
      );
      final Pointer<OrtTensorTypeAndShapeInfo> info = infoOut.value;
      try {
        final Pointer<Size> dimCountOut = calloc<Size>();
        final Pointer<UnsignedInt> typeOut = calloc<UnsignedInt>();
        final Pointer<Size> elementCountOut = calloc<Size>();
        try {
          checkOrtStatus(
            api,
            api.ref.GetDimensionsCount.asFunction<
                Pointer<OrtStatus> Function(
                    Pointer<OrtTensorTypeAndShapeInfo>,
                    Pointer<Size>)>()(info, dimCountOut),
          );
          final int dimCount = dimCountOut.value;
          final Pointer<Int64> dims = calloc<Int64>(dimCount);
          try {
            checkOrtStatus(
              api,
              api.ref.GetDimensions.asFunction<
                  Pointer<OrtStatus> Function(
                      Pointer<OrtTensorTypeAndShapeInfo>,
                      Pointer<Int64>,
                      int)>()(info, dims, dimCount),
            );
            checkOrtStatus(
              api,
              api.ref.GetTensorElementType.asFunction<
                  Pointer<OrtStatus> Function(
                      Pointer<OrtTensorTypeAndShapeInfo>,
                      Pointer<UnsignedInt>)>()(info, typeOut),
            );
            checkOrtStatus(
              api,
              api.ref.GetTensorShapeElementCount.asFunction<
                  Pointer<OrtStatus> Function(
                      Pointer<OrtTensorTypeAndShapeInfo>,
                      Pointer<Size>)>()(info, elementCountOut),
            );
            final List<int> shape = <int>[
              for (int i = 0; i < dimCount; i++) dims[i],
            ];
            final int count = elementCountOut.value;
            final Pointer<Pointer<Void>> dataOut = calloc<Pointer<Void>>();
            try {
              checkOrtStatus(
                api,
                api.ref.GetTensorMutableData.asFunction<
                    Pointer<OrtStatus> Function(
                        Pointer<OrtValue>, Pointer<Pointer<Void>>)>()(
                    value, dataOut),
              );
              return _copyOut(typeOut.value, dataOut.value, count, shape);
            } finally {
              calloc.free(dataOut);
            }
          } finally {
            calloc.free(dims);
          }
        } finally {
          calloc.free(dimCountOut);
          calloc.free(typeOut);
          calloc.free(elementCountOut);
        }
      } finally {
        api.ref.ReleaseTensorTypeAndShapeInfo.asFunction<
            void Function(Pointer<OrtTensorTypeAndShapeInfo>)>()(info);
      }
    } finally {
      calloc.free(infoOut);
    }
  }

  /// 把 ORT 拥有的输出内存复制进 Dart 堆。
  ///
  /// **必须复制**：那块内存归 `OrtValue` 所有，`ReleaseValue` 之后就无效了；
  /// `asTypedList` 只是个视图。
  static OnnxTensor _copyOut(
    int elementType,
    Pointer<Void> data,
    int count,
    List<int> shape,
  ) {
    const int kFloat =
        1; // ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
    const int kInt32 = 6;
    const int kInt64 = 7;
    switch (elementType) {
      case kFloat:
        return OnnxTensor.float32(
          Float32List.fromList(data.cast<Float>().asTypedList(count)),
          shape,
        );
      case kInt64:
        return OnnxTensor.int64(
          Int64List.fromList(data.cast<Int64>().asTypedList(count)),
          shape,
        );
      case kInt32:
        return OnnxTensor.int32(
          Int32List.fromList(data.cast<Int32>().asTypedList(count)),
          shape,
        );
      default:
        throw OrtException(
          1,
          '不支持的输出元素类型 $elementType（本层只处理 float32 / int32 / int64）',
        );
    }
  }
}

/// 一次 `run` 期间的 native 内存池。
///
/// `CreateTensorWithDataAsOrtValue` **不拷贝也不拥有** `p_data`，所以每块输入内存
/// 必须活到对应 `OrtValue` 被 release 之后。逐块手工 free 太容易漏，统一到这里。
class _RunArena {
  final List<Pointer<NativeType>> _blocks = <Pointer<NativeType>>[];
  Pointer<OrtMemoryInfo>? _memoryInfo;
  Pointer<OrtApi>? _api;

  // calloc<T> 要求类型在编译期已知，所以按用到的类型逐个开口，而不是一个泛型
  // allocate<T>。种类就这几种，摊开比绕过类型系统清楚。
  Pointer<Float> allocFloat(int count) => _track(calloc<Float>(count));
  Pointer<Int32> allocInt32(int count) => _track(calloc<Int32>(count));
  Pointer<Int64> allocInt64(int count) => _track(calloc<Int64>(count));
  Pointer<Pointer<Char>> allocCharPtrs(int count) =>
      _track(calloc<Pointer<Char>>(count));
  Pointer<Pointer<OrtValue>> allocValuePtrs(int count) =>
      _track(calloc<Pointer<OrtValue>>(count));

  Pointer<T> _track<T extends NativeType>(Pointer<T> p) {
    _blocks.add(p);
    return p;
  }

  Pointer<Char> utf8(String s) {
    final Pointer<Utf8> p = s.toNativeUtf8();
    _blocks.add(p);
    return p.cast<Char>();
  }

  Pointer<OrtMemoryInfo> cpuMemoryInfo(Pointer<OrtApi> api) {
    final Pointer<OrtMemoryInfo>? existing = _memoryInfo;
    if (existing != null) return existing;
    _api = api;
    final Pointer<Pointer<OrtMemoryInfo>> out = calloc<Pointer<OrtMemoryInfo>>();
    try {
      checkOrtStatus(
        api,
        api.ref.CreateCpuMemoryInfo.asFunction<
            Pointer<OrtStatus> Function(
          int,
          int,
          Pointer<Pointer<OrtMemoryInfo>>,
        )>()(
          OrtAllocatorType.OrtArenaAllocator.value,
          OrtMemType.OrtMemTypeDefault.value,
          out,
        ),
      );
      return _memoryInfo = out.value;
    } finally {
      calloc.free(out);
    }
  }

  void releaseAll() {
    final Pointer<OrtMemoryInfo>? info = _memoryInfo;
    final Pointer<OrtApi>? api = _api;
    if (info != null && api != null) {
      api.ref.ReleaseMemoryInfo
          .asFunction<void Function(Pointer<OrtMemoryInfo>)>()(info);
      _memoryInfo = null;
    }
    for (final Pointer<NativeType> block in _blocks) {
      calloc.free(block);
    }
    _blocks.clear();
  }
}
