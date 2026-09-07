// FFI 后端冒烟：装载真 onnxruntime、建会话、跑一次推理、读回输出。
//
// 用法：dart run tool/ort_smoke.dart <模型.onnx>
// 库路径经 ASR_ONNXRUNTIME_LIB 指定。
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_asr_onnx_ffi/asr_onnx_ffi.dart';

Future<void> main(List<String> args) async {
  final OrtRuntime rt = OrtRuntime.instance();
  stdout.writeln('ORT 版本: ${rt.versionString}');
  stdout.writeln('库路径: ${rt.libraryPath}');

  final FfiOnnxSessionFactory factory = FfiOnnxSessionFactory();
  final Set<OnnxExecutionProvider> eps =
      await factory.availableAcceleratedProviders();
  stdout.writeln('加速 EP: ${eps.map((OnnxExecutionProvider e) => e.name).join(", ")}');

  if (args.isEmpty) return;
  final OnnxSession session = await factory.createSession(
    args.first,
    providers: const <OnnxExecutionProvider>[OnnxExecutionProvider.cpu],
    onProviderResolved: (OnnxProviderResolution r) =>
        stdout.writeln('provider: $r'),
  );
  final FfiOnnxSession s = session as FfiOnnxSession;
  stdout.writeln('输入: ${s.inputNames}');
  stdout.writeln('输出: ${s.outputNames}');
  stdout.writeln('输入形状: ${s.inputShapes}');
  await session.close();
  stdout.writeln('OK');
}
