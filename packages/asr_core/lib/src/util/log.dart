/// 库级日志出口。
///
/// 存在的理由：这套代码原本住在 Flutter app 里，直接调 `debugPrint`。抽成独立包后
/// 不能再假设宿主是 Flutter——CLI 要往 stderr 写、服务端要进结构化日志、Flutter 宿主
/// 想要 `debugPrint` 的分帧节流。所以出口做成可替换的单点，默认写 stderr
/// （**不是 stdout**：CLI 会把 SRT 直接吐到 stdout，日志混进去就毁了管道输出）。
library;

import 'dart:io';

/// 日志接收端签名。
typedef AsrLogSink = void Function(String message);

/// 当前日志出口。宿主可整体替换，例如 Flutter 侧 `asrLogSink = debugPrint;`。
AsrLogSink asrLogSink = _defaultSink;

void _defaultSink(String message) {
  stderr.writeln(message);
}

/// 写一行日志。
void asrLog(String message) => asrLogSink(message);

/// 关停 / 收尾阶段的诊断开关：`ASR_TRACE_SHUTDOWN=1` 时把每一步写 stderr。
///
/// 存在的理由是一次真事故：转录跑完之后连接不关，从客户端看只是「一直等」，
/// 分不清卡在关会话、关 PCM 桥、退出消息没送到，还是服务端写响应时抛了。这几步
/// 分别在三个文件里，各写一遍 env 判断只会漂移，所以收成一个开关。
///
/// 诊断用，生产不设。
final bool kAsrTraceShutdown =
    Platform.environment['ASR_TRACE_SHUTDOWN'] == '1';

/// 关停阶段打一行（未开开关时什么都不做）。
void asrShutdownTrace(String message) {
  if (!kAsrTraceShutdown) return;
  stderr.writeln('[asr-shutdown] $message');
}
