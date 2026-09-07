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
