/// 候选选择判据的回归测试。
///
/// 真 bug（2026-09-08）：`_open` 在 `DynamicLibrary.open` 成功处就 break，把版本
/// 检查放在循环外。Windows 的 System32 里躺着一份随系统装的 ORT 1.17.1，裸库名
/// 恒定先搜到它，于是整条候选链被它毒死——后面真正可用的运行时永远轮不到，
/// 转录一律以「不支持 API 版本 22」失败。判据必须是「打得开 **且** 版本够」。
library;

import 'package:fushi_asr_onnx_ffi/src/ort_runtime.dart';
import 'package:test/test.dart';

/// 假探测：`usable` 里的候选算可用，其余按给定原因失败。
(String?, String?) Function(String) fakeProbe(
  Set<String> usable, {
  List<String>? probed,
}) =>
    (String candidate) {
      probed?.add(candidate);
      if (usable.contains(candidate)) return (candidate, null);
      return (null, '版本 1.17.1，不支持 API 版本 22');
    };

void main() {
  group('候选选择', () {
    test('第一个打得开但版本不够时，继续试后面的候选', () {
      final List<String> failures = <String>[];
      final List<String> probed = <String>[];
      final String? picked = OrtRuntime.selectUsableCandidate<String>(
        <String>['C:/Windows/System32/onnxruntime.dll', 'D:/good/onnxruntime.dll'],
        fakeProbe(<String>{'D:/good/onnxruntime.dll'}, probed: probed),
        failures,
      );
      // 核心断言：不是停在第一个，而是走到了真正可用的那个。
      expect(picked, 'D:/good/onnxruntime.dll');
      expect(probed, hasLength(2), reason: '旧实现只会探第一个就 break');
      expect(failures, hasLength(1));
      expect(failures.single, contains('System32'));
      expect(failures.single, contains('不支持 API 版本 22'));
    });

    test('全部不可用时返回 null，且逐条留下「哪个候选、为什么」', () {
      final List<String> failures = <String>[];
      final String? picked = OrtRuntime.selectUsableCandidate<String>(
        <String>['a.dll', 'b.dll', 'c.dll'],
        fakeProbe(const <String>{}),
        failures,
      );
      expect(picked, isNull);
      expect(failures, hasLength(3));
      for (final String f in failures) {
        expect(f, contains('：'), reason: '要能看出是哪个候选失败的');
      }
    });

    test('第一个就可用时不再探后面的', () {
      final List<String> probed = <String>[];
      final String? picked = OrtRuntime.selectUsableCandidate<String>(
        <String>['good.dll', 'never.dll'],
        fakeProbe(<String>{'good.dll'}, probed: probed),
        <String>[],
      );
      expect(picked, 'good.dll');
      expect(probed, <String>['good.dll']);
    });

    test('探测没给原因时也要记一条，不能让候选静默消失', () {
      final List<String> failures = <String>[];
      OrtRuntime.selectUsableCandidate<String>(
        <String>['x.dll'],
        (String c) => (null, null),
        failures,
      );
      expect(failures.single, contains('x.dll'));
    });
  });

  group('真库探测', () {
    test('不存在的路径报「打不开」而不是抛出去', () {
      final (Object? value, String? failure) =
          OrtRuntime.probeCandidate('D:/definitely/not/here/onnxruntime.dll');
      expect(value, isNull);
      expect(failure, contains('打不开'));
    });
  });
}
