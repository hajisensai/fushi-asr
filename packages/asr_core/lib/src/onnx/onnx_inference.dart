/// 与业务无关的 ONNX 推理会话抽象层（OCR / ASR 共用）。
///
/// 把 `flutter_onnxruntime` 包在窄接口后面：算法层只依赖 [OnnxSession] /
/// [OnnxTensor]，单元测试用 fake 实现即可，不需要真模型或 native 绑定。
/// 真实现见 `onnx_inference_ort.dart`。
///
/// 历史：这套类型最初以 `Ocr*` 前缀住在 `lib/src/ocr/ocr_inference.dart`，
/// 有声书 ASR 接入后抬到本文件成为唯一定义；`ocr_inference.dart` 里的 `Ocr*`
/// 名字保留为 typedef 别名，OCR 调用方零改动。
library;

import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

/// 支持的张量元素类型：float32 / int64 给 OCR 与大多数 ASR 模型；int32 给把
/// 索引张量导成 int32 的 ASR 导出（X-ASR zipformer，`asr_model_manifest.dart`）。
enum OnnxTensorType { float32, int64, int32 }

/// 不可变张量：扁平数据 + 形状。
class OnnxTensor {
  OnnxTensor.float32(Float32List data, this.shape)
      : type = OnnxTensorType.float32,
        floatData = data,
        intData = null,
        int32Data = null {
    _checkLength(data.length);
  }

  OnnxTensor.int64(Int64List data, this.shape)
      : type = OnnxTensorType.int64,
        floatData = null,
        intData = data,
        int32Data = null {
    _checkLength(data.length);
  }

  OnnxTensor.int32(Int32List data, this.shape)
      : type = OnnxTensorType.int32,
        floatData = null,
        intData = null,
        int32Data = data {
    _checkLength(data.length);
  }

  final OnnxTensorType type;
  final List<int> shape;
  final Float32List? floatData;
  final Int64List? intData;
  final Int32List? int32Data;

  int get elementCount => shape.fold<int>(1, (int acc, int dim) => acc * dim);

  void _checkLength(int length) {
    if (length != elementCount) {
      throw ArgumentError(
          'OnnxTensor data length $length does not match shape $shape '
          '($elementCount elements)');
    }
  }
}

/// 一次可运行的 ONNX 会话。
abstract interface class OnnxSession {
  /// 运行推理：输入/输出均为 名字 -> 张量。
  ///
  /// 输出张量的元素类型由实现决定；`flutter_onnxruntime` 实现把所有输出读成
  /// float32（int64 输出以整数值落在 float 里，调用方 `round()` 取回）。
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs);

  /// 释放 native 资源。
  Future<void> close();
}

/// 会话工厂：模型文件路径由调用方注入（模型下载管理不在本层）。
abstract interface class OnnxSessionFactory {
  /// [intraOpNumThreads]：ORT 单算子内并行线程数；null 用 ORT 默认（全核）。
  /// 小矩阵逐帧型的图（ASR 贪心 Loop 图）全核反而慢，调用方按实测传。
  ///
  /// [freeDimensionOverrides]：把模型输入的符号维度（如 `N` / `T`）钉成固定值
  /// （ORT `AddFreeDimensionOverrideByName`）。全部输入 shape 静态后 ORT 能在建
  /// 会话时把整图融合/编译一次，而不是每次 run 重新规划——DirectML 上 zipformer
  /// 编码器吞吐 5~7 倍（见 `asr_encoder_buckets.dart`）。之后喂进来的张量必须
  /// **恰好**是这些维度。只有 Windows 插件实现了此项，其它平台忽略。
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    void Function(OnnxProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  });

  /// 探测本机 ONNX 运行时**编译进来**的加速 EP 集合，喂给 EP 选择纯函数
  /// （`selectAsrEncoderProviders`）。
  ///
  /// **语义边界**：回报的是「该 EP 编译进了当前 onnxruntime 运行时」，**不是**
  /// 「它此刻真能建出会话」（DirectML 还要能建出 D3D12 设备，CUDA 还要有驱动和
  /// 可用显卡）。必要不充分，别拿它当运行期可用性的结论——建会话那层的 CPU 回退
  /// 因此不是死代码。
  ///
  /// 探测本身失败是一条真实的降级路径（有 N 卡也会退到 CPU），**不允许实现方
  /// 静默吞异常**：抛出来，由调用方捕获后记进可观测的降级说明。
  Future<Set<OnnxExecutionProvider>> availableAcceleratedProviders();

  /// GPU 显存预算（字节；本进程可分配上限）。无 GPU、平台不支持、查询失败都返回
  /// null —— 调用方按「未知」处理，**不当成 0**。
  ///
  /// 消费方是静态桶表的显存门（`asr_encoder_buckets.dart`）：静态融合图把全部中间
  /// 张量一次性分配并常驻，装不下不会报错而是溢出到主机内存、吞吐崩塌。所以这个
  /// 查询不是锦上添花，是桶表能不能开大的唯一依据。
  Future<int?> deviceMemoryBudgetBytes();
}

/// 执行后端（execution provider）。
enum OnnxExecutionProvider { cuda, directml, coreml, cpu }

/// 一次会话创建实际落到哪个执行后端，以及（若发生）降级原因。
///
/// 粒度就是插件边界能给出的粒度：`flutter_onnxruntime` 只回报「整张 provider
/// 列表被接受」或「被拒绝」，不告诉我们 ORT 内部最终选中的 EP。因此
/// [effective] 的语义是「本次真正提交给 ORT 的首选 provider」——列表被接受时
/// 是 [requested] 的首项，被拒绝并回退时是 [OnnxExecutionProvider.cpu]。
///
/// 存在的唯一理由：降级路径必须显式可观测。把 GPU 静默换成 CPU 会让用户在
/// 整卷 OCR / 整本转录这种耗时任务上误判性能，本仓不允许无声降级。
class OnnxProviderResolution {
  const OnnxProviderResolution({
    required this.requested,
    required this.effective,
    this.fallbackReason,
  });

  /// 调用方按平台策略请求的 provider 列表（首项为首选）。
  final List<OnnxExecutionProvider> requested;

  /// 本次会话真正提交给 ORT 的首选 provider。
  final OnnxExecutionProvider effective;

  /// 降级原因；null 表示未降级。
  final String? fallbackReason;

  bool get didFallBack => fallbackReason != null;

  @override
  String toString() {
    if (!didFallBack) return 'OnnxProviderResolution(${effective.name})';
    final String from = requested.isEmpty ? 'none' : requested.first.name;
    return 'OnnxProviderResolution($from -> ${effective.name}: '
        '$fallbackReason)';
  }
}

/// `FUSHI_ASR_TRACE=<文件路径>`：每次 [OnnxSession.run] 追加一行分步耗时
/// （建输入张量 / Run / 读回输出 / 释放），encode 也记张量填充耗时——Dart↔插件
/// 往返有多贵只能这样量，`AsrDecodeStats` 的分段计时把等待都算在一起分不出来。
/// 落文件而不是 stdout：转录跑在后台 isolate，那里的 `print` 进不了集成测试的
/// command.log。诊断开关，生产不设。
final String? kOnnxTraceFile = () {
  final String? v = Platform.environment['FUSHI_ASR_TRACE'];
  return v == null || v.isEmpty ? null : v;
}();

bool get kOnnxTraceEnabled => kOnnxTraceFile != null;

/// 追加一行 trace（同步小写；只在 [kOnnxTraceEnabled] 时调）。
void onnxTrace(String line) {
  final String? path = kOnnxTraceFile;
  if (path == null) return;
  File(path).writeAsStringSync(
    '${DateTime.now().toIso8601String()} $line\n',
    mode: FileMode.append,
    flush: true,
  );
}

/// 本平台是否**可能**有本地 ONNX Runtime（= 该端有 native 实现随包）。
///
/// 保留这个具名闸门而不是直接写 `true`：它是「本地推理可不可用」的唯一判定点，
/// 将来任一端的 native 被摘掉（换 ORT 版本、平台下限回退），只改这里，调用方无须
/// 改动。注意它是**平台层**的必要条件，不是「此刻真能建出会话」——后者由注入的
/// [OnnxSessionFactory] 说了算。
bool get isLocalOnnxRuntimeAvailable =>
    Platform.isWindows ||
    Platform.isLinux ||
    Platform.isAndroid ||
    Platform.isMacOS ||
    Platform.isIOS;

/// 本层写日志用的默认通道名。
const String kOnnxLogName = 'asr.onnx';

/// 把「建会话失败」的异常描述成 [OnnxProviderResolution.fallbackReason]。
///
/// 后端可替换：Flutter 插件后端把 `PlatformException` 拆成 `code: message`
/// （native 把非 UTF-8 字节送过 channel 时 Dart 侧抛的 `FormatException`，那串
/// 偏移量本身就是排查线索，不该被抹成一句「未知错误」）。默认用 `toString`。
String Function(Object error) onnxProviderFailureDescriber =
    (Object error) => '$error';

/// 用配置的加速 EP 创建会话；首选 EP 建不起来时，按 [providers] 中已有的 CPU
/// 后备重试一次。
///
/// 判据是**「首选 EP 没建成会话」**，不是某一个错误码。加速 EP 失败的形态本来
/// 就不止一种：后端不认识这个 provider 会在建 session 之前抛错；而 ORT 自己
/// 初始化 EP 失败是在建 session 之中抛 `ORT_ERROR`——实测 DirectML 初始化 int8
/// 模型时抛 `E_INVALIDARG (80070057)`，走的正是后一条路。按错误码枚举「哪种失败
/// 才算 EP 问题」注定漏，而漏掉的代价是整条链路直接不可用：列表尾部那个 CPU
/// 后备明明在，却一次都轮不到。
///
/// 「模型损坏也会被多试一次 CPU」是这么换来的，而且这笔交易划算：那种输入下
/// CPU 同样建不成，最终照样抛错，只是多花一次失败的时间；反过来，为了省这一次
/// 而维护一张错误码白名单，换来的是真·EP 故障时功能整个躺平。
///
/// CPU 重试也失败时抛出的是**CPU 那次**的异常（类型与内容都不变，调用方原有的
/// catch 子句照旧成立），首选 EP 的失败则落进日志——两次失败都得留痕，回退不能
/// 变成「把第一个错误吃掉」。
///
/// [onResolved] 在会话建成后**必定**被调用一次，回报本次真正生效的 provider
/// 与降级原因：降级不允许静默发生，调用层据此写日志并把状态送到 UI。回调本身抛出
/// 的异常不影响会话创建结果，只落日志。
Future<T> createOnnxSessionWithProviderFallback<T>({
  required List<OnnxExecutionProvider> providers,
  required Future<T> Function(List<OnnxExecutionProvider> providers) create,
  void Function(OnnxProviderResolution resolution)? onResolved,
  String logName = kOnnxLogName,
}) async {
  final OnnxExecutionProvider preferred =
      providers.isEmpty ? OnnxExecutionProvider.cpu : providers.first;
  try {
    final T session = await create(providers);
    _notifyResolved(
      onResolved,
      OnnxProviderResolution(requested: providers, effective: preferred),
      logName,
    );
    return session;
  } on Exception catch (error) {
    final bool canRetryOnCpu = preferred != OnnxExecutionProvider.cpu &&
        providers.contains(OnnxExecutionProvider.cpu);
    if (!canRetryOnCpu) rethrow;
    developer.log(
      'ONNX session on ${preferred.name} failed; retrying on CPU',
      name: logName,
      error: error,
    );
    final T session;
    try {
      session = await create(const <OnnxExecutionProvider>[
        OnnxExecutionProvider.cpu,
      ]);
    } on Exception catch (cpuError) {
      developer.log(
        'ONNX session fell back to CPU and failed there too; '
        '${preferred.name} had failed with: $error',
        name: logName,
        error: cpuError,
      );
      rethrow;
    }
    _notifyResolved(
      onResolved,
      OnnxProviderResolution(
        requested: providers,
        effective: OnnxExecutionProvider.cpu,
        fallbackReason: onnxProviderFailureDescriber(error),
      ),
      logName,
    );
    return session;
  }
}

void _notifyResolved(
  void Function(OnnxProviderResolution resolution)? onResolved,
  OnnxProviderResolution resolution,
  String logName,
) {
  if (resolution.didFallBack) {
    developer.log(
      'ONNX execution provider fell back: $resolution',
      name: logName,
    );
  } else {
    developer.log(
      'ONNX execution provider resolved: $resolution',
      name: logName,
    );
  }
  if (onResolved == null) return;
  try {
    onResolved(resolution);
  } catch (error, stack) {
    developer.log(
      'ONNX provider resolution callback threw',
      name: logName,
      error: error,
      stackTrace: stack,
    );
  }
}
