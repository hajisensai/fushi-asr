/// 测试用 fake 工厂的探测方法缺省实现。
///
/// `availableAcceleratedProviders()` / `deviceMemoryBudgetBytes()` 是
/// [OnnxSessionFactory] 上的**平台探测**方法，只有 `AsrEngineLoader` 那一层会调。
/// 下层（编码器桶、CTC/transducer 解码器）的 fake 工厂从不碰它们，所以这里给一份
/// 「无加速 EP、显存未知」的缺省，免得每个 fake 各抄一遍。
///
/// 缺省值刻意选**保守**的一侧：探测不到加速 EP、显存按未知处理。真要断言这两个
/// 值的用例自己覆写。
library;

import 'package:asr_core/asr_core.dart';

mixin FakeOnnxFactoryProbes {
  Future<Set<OnnxExecutionProvider>> availableAcceleratedProviders() async =>
      const <OnnxExecutionProvider>{};

  Future<int?> deviceMemoryBudgetBytes() async => null;
}
