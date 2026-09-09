import 'dart:math' as math;

import 'package:fushi_asr_core/src/asr/asr_ctc_align.dart';
import 'package:fushi_asr_core/src/asr/asr_ctc_decoder.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';

/// Re-runs the acoustic model against the fixed transcript before publishing
/// timestamps. The caller owns the decoder/session lifecycle.
class AsrModelAligner {
  AsrModelAligner({
    required AsrCtcDecoder decoder,
    required AsrTokenTable tokens,
  }) : _decoder = decoder,
       _tokens = tokens,
       _encoder = AsrCtcTextEncoder(tokens);

  final AsrCtcDecoder _decoder;
  final AsrTokenTable _tokens;
  final AsrCtcTextEncoder _encoder;
  static final RegExp _nonSpeech = RegExp(r'^[\s\p{P}]*$', unicode: true);

  /// Keeps token strings and order intact; all returned offsets are newly
  /// derived from the second inference, never copied from the first pass.
  ///
  /// [AsrSegmentAlignment.rejected] = **这一段对不齐**：声学证据不足（第一遍
  /// 多半是对着音乐/环境音幻听出来的），或正文里能进声学路径的字符太少、无从
  /// 度量。这是正常结果不是错误，调用方丢掉这段继续跑即可——一段废音频不该炸
  /// 掉整份转录，但**必须记账**，见 [AsrAlignmentRejection]。
  ///
  /// 对齐成功时 [AsrSegmentAlignment.estimatedBoundaries] 如实报出有多少个
  /// token 端点是**推定**而非声学定位的（词表缺字压在 token 首/尾时会发生），
  /// 大于 0 就不能当成完整的声学对齐。
  ///
  /// 仍然抛异常的只剩**装配错误**（词表形态不对、模型输出宽度与词表不符、对齐
  /// 结果越界或逆序）：那是程序员错误，掩盖它只会让人多调试几天。
  Future<AsrSegmentAlignment> align(
    AsrSpeechSegment speech,
    AsrDecodedSegment transcript,
  ) async {
    if (transcript.isEmpty) {
      return AsrSegmentAlignment.aligned(AsrDecodedSegment.empty);
    }
    if (!_encoder.isSupported) {
      throw StateError('字幕调轴需要字符级 CTC 词表，当前词表不受支持');
    }
    final List<int> targets = <int>[];
    final List<int> owners = <int>[];
    int speechCharacters = 0;
    int unmappedCharacters = 0;
    final int tokenCount = transcript.tokens.length;
    // 缺字压在 token 首/尾时，那一端的真实时刻定不下来：缺字**发声**，不像标点。
    // 拿同一个 token 里已知字的时刻去当边界，字幕就会晚出现或早消失。
    final List<bool> startEstimated = List<bool>.filled(tokenCount, false);
    final List<bool> endEstimated = List<bool>.filled(tokenCount, false);
    for (int i = 0; i < tokenCount; i++) {
      bool mappedSeen = false;
      bool unmappedAfterLastMapped = false;
      for (final int rune in transcript.tokens[i].runes) {
        final String character = String.fromCharCode(rune);
        // Punctuation is silent. Do not force it into the acoustic path even
        // when the vocabulary happens to contain a punctuation token.
        if (_nonSpeech.hasMatch(character)) continue;
        speechCharacters++;
        AsrCtcEncodedText encoded = _encoder.encode(character);
        if (encoded.isEmpty) encoded = _encoder.encode(character.toLowerCase());
        if (encoded.isEmpty) {
          // 词表外字符与标点同路：跳过，不进声学路径，时间由相邻锚点继承
          // （[AsrCtcTextEncoder.encode] 本来就是「查不到就跳过」的语义，填
          // `<unk>` 会吸收任意帧、毁掉对齐）。一遍模型与调轴模型是两张互不相
          // 干的字符表——实测日语 transducer 能吐出的 4823 个汉字里有 1302 个
          // （27%）不在 Omnilingual 调轴词表里，把这种常态当致命错误，等于让
          // 任何一段日语正文都可能随时炸掉整份转录。
          unmappedCharacters++;
          if (mappedSeen) {
            unmappedAfterLastMapped = true;
          } else {
            startEstimated[i] = true;
          }
          continue;
        }
        mappedSeen = true;
        unmappedAfterLastMapped = false;
        targets.addAll(encoded.ids);
        owners.addAll(List<int>.filled(encoded.length, i));
      }
      // 整个 token 都缺字时两端都定不下来（标点-only 的 token 两端都不算推定：
      // 它本来就不发声，零时长继承是对的）。
      endEstimated[i] =
          unmappedAfterLastMapped || (startEstimated[i] && !mappedSeen);
    }
    if (speech.samples.isEmpty) {
      throw StateError('字幕调轴缺少可对齐的音频');
    }
    // 能落到声学路径的字符不到一半时，剩下的锚点撑不住整段正文的时间分配：
    // 判这段无从度量，交给调用方丢弃，而不是拿半份证据硬对出一份假时间。
    if (targets.isEmpty || unmappedCharacters * 2 > speechCharacters) {
      return const AsrSegmentAlignment.rejected(
        AsrAlignmentRejection.tooFewMappableCharacters,
      );
    }
    final AsrCtcLogits logits = await _decoder.runLogits(speech.samples);
    if (logits.vocab != _tokens.size || logits.frames <= 0) {
      throw StateError('字幕调轴模型输出与词表不匹配或没有音频帧');
    }
    final AsrCtcAlignment? alignment = ctcForcedAlign(
      logits: logits.logits,
      frames: logits.frames,
      vocab: logits.vocab,
      targets: targets,
      blankId: _tokens.blankId,
    );
    if (alignment == null || !alignment.totalLogProb.isFinite) {
      // 音频帧不足 / 对齐预算超限 / 路径概率下溢：这一段对不出可信路径。
      return const AsrSegmentAlignment.rejected(
        AsrAlignmentRejection.noViterbiPath,
      );
    }
    // A forced path exists even for unrelated/silent audio. Require acoustic
    // evidence above a uniform vocabulary distribution instead of accepting
    // any finite Viterbi path as successful alignment.
    final double evidence =
        alignment.tokens.fold<double>(
          0,
          (double sum, AsrCtcAlignedToken token) => sum + token.meanLogProb,
        ) /
        alignment.tokens.length;
    if (!evidence.isFinite || evidence <= -math.log(logits.vocab)) {
      // 比在整个词表上均匀瞎猜还差 = 这段音频根本没在说这段正文。门槛保持
      // `-ln(vocab)` 这条硬下界，不要为了让某个素材通过而放宽它：放宽只会把
      // 幻听 cue 放进字幕，而这里正是整条流水线上唯一存在的置信度信号
      // （一遍的 RNN-T 贪心解码只取 argmax，不产出任何置信度）。
      return const AsrSegmentAlignment.rejected(
        AsrAlignmentRejection.noAcousticEvidence,
      );
    }
    final List<int?> starts = List<int?>.filled(transcript.tokens.length, null);
    final List<int?> ends = List<int?>.filled(transcript.tokens.length, null);
    for (int i = 0; i < alignment.tokens.length; i++) {
      final int offset = (alignment.tokens[i].startFrame * logits.frameMs)
          .round();
      if (offset < 0 || offset >= speech.lengthMs) {
        throw StateError('字幕调轴生成了超出音频范围的时间');
      }
      starts[owners[i]] ??= offset;
      ends[owners[i]] = math.min(
        speech.lengthMs,
        (alignment.tokens[i].endFrame * logits.frameMs).round(),
      );
    }
    // 端点推定：缺字压在首/尾的那一端，用相邻**声学**锚点兜住，而不是用同一个
    // token 里已知字的时刻。宁可早出（cue 提前一点无害），绝不允许把字音切掉。
    // 两趟都只读原始声学锚点，推定值不会再被下一个推定值当成锚点用。
    final List<int?> acousticStarts = List<int?>.of(starts);
    final List<int?> acousticEnds = List<int?>.of(ends);
    int estimatedBoundaries = 0;
    int? previousAcousticEnd;
    for (int i = 0; i < tokenCount; i++) {
      if (startEstimated[i]) {
        starts[i] = previousAcousticEnd ?? 0;
        estimatedBoundaries++;
      }
      if (acousticEnds[i] != null) previousAcousticEnd = acousticEnds[i];
    }
    int? nextAcousticStart;
    for (int i = tokenCount - 1; i >= 0; i--) {
      if (endEstimated[i]) {
        ends[i] = nextAcousticStart ?? speech.lengthMs;
        estimatedBoundaries++;
      }
      if (acousticStarts[i] != null) nextAcousticStart = acousticStarts[i];
    }
    // Silent tokens inherit the preceding acoustic anchor; leading punctuation
    // inherits the first following anchor. No old ASR timestamp is consulted.
    final int first = starts.firstWhere((int? value) => value != null)!;
    int previous = first;
    int previousEnd = first;
    final List<int> offsets = <int>[];
    final List<int> endOffsets = <int>[];
    for (int i = 0; i < starts.length; i++) {
      final int current = starts[i] ?? previousEnd;
      if (current < previous) throw StateError('字幕调轴生成了逆序时间');
      offsets.add(current);
      endOffsets.add(ends[i] ?? current);
      previous = current;
      previousEnd = endOffsets.last;
    }
    return AsrSegmentAlignment.aligned(
      AsrDecodedSegment(
        tokens: List<String>.unmodifiable(transcript.tokens),
        tokenOffsetsMs: List<int>.unmodifiable(offsets),
        tokenEndOffsetsMs: List<int>.unmodifiable(endOffsets),
      ),
      estimatedBoundaries: estimatedBoundaries,
    );
  }
}
