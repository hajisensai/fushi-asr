/// EPUB / 文本 ↔ 音频对齐。
///
/// 三层：
/// 1. [EpubSrtMatcher]：把字幕 cue 与正文句子对上（精确 + 模糊两个通道，
///    带 ruby 读音轨兜住漢字↔かな）；
/// 2. [AnchorGapFiller]：用两侧已命中的锚点把中间没命中的段捞回来；
/// 3. [resegmentCuesBySentence]：命中的 cue 用逐 token 发射时间按正文句界重切，
///    消掉「一条 cue 盖了好几句」。
///
/// cue 类型是 [AlignCue]，宿主让自己的类继承它即可（见 [AlignCue] 的文件注释）。
library;

export 'src/anchor_gap_filler.dart';
export 'src/align_cue.dart';
export 'src/audio_text_normalizer.dart';
export 'src/cue_sentence_resegmenter.dart';
export 'src/epub_cue_matcher.dart';
export 'src/epub_srt_matcher.dart';
export 'src/epub_reader.dart';
