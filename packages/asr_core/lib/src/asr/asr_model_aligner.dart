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
  Future<AsrDecodedSegment> align(
    AsrSpeechSegment speech,
    AsrDecodedSegment transcript,
  ) async {
    if (transcript.isEmpty) return AsrDecodedSegment.empty;
    if (!_encoder.isSupported) {
      throw StateError('字幕调轴需要字符级 CTC 词表，当前词表不受支持');
    }
    final List<int> targets = <int>[];
    final List<int> owners = <int>[];
    for (int i = 0; i < transcript.tokens.length; i++) {
      for (final int rune in transcript.tokens[i].runes) {
        final String character = String.fromCharCode(rune);
        // Punctuation is silent. Do not force it into the acoustic path even
        // when the vocabulary happens to contain a punctuation token.
        if (_nonSpeech.hasMatch(character)) continue;
        AsrCtcEncodedText encoded = _encoder.encode(character);
        if (encoded.isEmpty) encoded = _encoder.encode(character.toLowerCase());
        if (encoded.isEmpty) {
          throw StateError(
            '字幕调轴模型词表不支持正文字符 U+${rune.toRadixString(16).toUpperCase()}',
          );
        }
        targets.addAll(encoded.ids);
        owners.addAll(List<int>.filled(encoded.length, i));
      }
    }
    if (targets.isEmpty || speech.samples.isEmpty) {
      throw StateError('字幕调轴缺少可对齐的正文或音频');
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
      throw StateError('字幕调轴无法建立有效路径：音频帧不足、对齐预算超限或模型输出无效');
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
      throw StateError('字幕调轴未找到足够的正文语音证据');
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
    return AsrDecodedSegment(
      tokens: List<String>.unmodifiable(transcript.tokens),
      tokenOffsetsMs: List<int>.unmodifiable(offsets),
      tokenEndOffsetsMs: List<int>.unmodifiable(endOffsets),
    );
  }
}
