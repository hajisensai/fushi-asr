/// 对齐层的 cue 类型。
library;

import 'package:fushi_asr_core/asr_core.dart' show AsrCueTokenTiming;

/// 单条对齐片段，粒度为句子级别。
///
/// **设计成可继承的基类而不是一个要来回转换的 DTO**：宿主（Hibiki）的 `AudioCue`
/// 在这几个字段之外还有数据库主键和渲染用的行内样式，而匹配层一个都不碰
/// （实测只用到下面 9 个字段）。让宿主的类 `extends AlignCue` 就同时得到两件事：
/// 匹配器直接吃宿主的对象，零转换；宿主往数据库写的还是它自己的类型，落库那一侧
/// 一行都不用改。反过来做成独立 DTO 就得在边界上抄字段——抄漏一个是静默丢数据。
///
/// 字段全是 `late` 无参构造，与宿主既有形态一致（宿主是逐字段 `..field =` 赋值的）。
class AlignCue {
  /// 所属作品的键（宿主自己的书 uid / SRT uid）。
  late String bookKey;

  /// 章节标识，例如 EPUB spine item `OEBPS/ch01.xhtml`。
  late String chapterHref;

  /// 章节内句序（0 起）。
  late int sentenceIndex;

  /// DOM id 或 CSS selector，用于阅读器高亮定位，例如 `#s1`。
  late String textFragmentId;

  /// 原文文本（模糊兜底匹配用）。
  late String text;

  /// 片段开始时间（毫秒，相对当前音频文件）。
  late int startMs;

  /// 片段结束时间（毫秒，相对当前音频文件）。
  late int endMs;

  /// 多段音频时的文件下标。
  late int audioFileIndex;

  /// 转录产物附带的逐 token 发射时间（瞬态，不持久化）。
  ///
  /// 由转录任务目录的 sidecar 挂上来（`AsrTranscriptionService.readCueTokenTimings`），
  /// 供匹配后按正文句界重切 cue（[resegmentCuesBySentence]）。
  AsrCueTokenTiming? tokenTiming;
}
