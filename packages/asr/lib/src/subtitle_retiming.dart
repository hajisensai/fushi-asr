/// Repair existing subtitle timestamps using conservative textual ASR anchors.
/// Original cue bodies and their order are never replaced or resegmented.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:asr_align/asr_align.dart' show AudioTextNormalizer;
import 'package:asr_core/asr_core.dart' show AsrCueTokenTiming;

import 'cancellation.dart';
import 'subtitle_format.dart';
import 'subtitle_speech_text.dart';
import 'subtitle_clock.dart';
import 'transcribe_runner.dart';

const int maxSubtitleBytes = 8 * 1024 * 1024;
const int _maxCues = 20000;
const int _maxTextLength = 500000;
const int _maxCueLength = 8192;
const int _gramSize = 4;
const int _maxOccurrences = 24;

final _srtTime = RegExp(r'^(\d{2,5}):(\d{2}):(\d{2})[,.](\d{3})$');
final _vttTime = RegExp(r'^(?:(\d{2,5}):)?(\d{2}):(\d{2})\.(\d{3})$');
final _tags = RegExp(r'<[^<>]*>|\{\\[^{}]*\}');
final _unicodeText = RegExp(r'^[\p{L}\p{N}\p{M}]$', unicode: true);

/// Parse UTF-8-decoded SRT or WebVTT, rejecting malformed cues rather than
/// silently dropping text. VTT styling, identifiers and settings are not carried
/// into the output; the original cue bodies (including inline markup) are.
List<SubtitleCue> parseRetimingSubtitles(String text) {
  if (text.length > maxSubtitleBytes ||
      utf8.encode(text).length > maxSubtitleBytes) {
    throw const FormatException('字幕超过 8 MiB 上限');
  }
  if (text.contains('\u0000')) {
    throw const FormatException('字幕包含无效字符，请使用 UTF-8 SRT 或 WebVTT');
  }
  text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  text = text.trimLeft();
  final blocks = text.split(RegExp(r'\n[ \t]*\n'));
  if (text.isEmpty) throw const FormatException('字幕没有有效条目');
  final header = blocks.first.split('\n');
  final isVtt = RegExp(r'^WEBVTT(?:[ \t].*)?$').hasMatch(header.first);
  if (isVtt) {
    if (header.any((line) => line.contains('-->'))) {
      throw const FormatException('WebVTT 文件头后需要空行');
    }
    blocks.removeAt(0);
  }
  final cues = <SubtitleCue>[];
  var totalText = 0;
  for (final block in blocks) {
    if (block.trim().isEmpty) continue;
    final lines = block.split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    if (isVtt &&
        (RegExp(r'^NOTE(?:[ \t].*)?$').hasMatch(lines.first) ||
            lines.first == 'STYLE' ||
            lines.first == 'REGION')) {
      continue;
    }
    final cueNumber = cues.length + 1;
    var timeLine = 0;
    if (!lines.first.contains('-->')) {
      if (!isVtt && !RegExp(r'^\d+$').hasMatch(lines.first.trim())) {
        throw FormatException('第 $cueNumber 条字幕的序号或时间轴无效');
      }
      timeLine = 1;
    }
    if (timeLine >= lines.length) {
      throw FormatException('第 $cueNumber 条字幕缺少时间轴');
    }
    final timing = lines[timeLine].trim().split(RegExp(r'\s+-->\s+'));
    if (timing.length != 2) {
      throw FormatException('第 $cueNumber 条字幕的时间轴无效');
    }
    final endParts = timing[1].split(RegExp(r'[ \t]+'));
    if (!isVtt && endParts.length != 1) {
      throw FormatException('第 $cueNumber 条 SRT 时间轴包含无效内容');
    }
    if (isVtt &&
        endParts.skip(1).any((setting) =>
            !RegExp(r'^[A-Za-z][A-Za-z-]*:\S+$').hasMatch(setting))) {
      throw FormatException('第 $cueNumber 条 WebVTT 设置无效');
    }
    final start = _parseTime(timing[0], isVtt);
    final end = _parseTime(endParts.first, isVtt);
    if (start == null || end == null || end <= start) {
      throw FormatException('第 $cueNumber 条字幕需要有效且递增的起止时间');
    }
    final bodyLines = lines.skip(timeLine + 1).toList();
    if (bodyLines
        .any((line) => RegExp(r'^\s*\d[\d:.,]*\s+-->').hasMatch(line))) {
      throw FormatException('第 $cueNumber 条字幕之后缺少空行分隔');
    }
    final body = bodyLines.join('\n');
    if (body.trim().isEmpty) {
      throw FormatException('第 $cueNumber 条字幕没有正文');
    }
    if (body.length > _maxCueLength) {
      throw FormatException('第 $cueNumber 条字幕过长（上限 $_maxCueLength 字符）');
    }
    totalText += body.length;
    if (totalText > _maxTextLength || cueNumber > _maxCues) {
      throw const FormatException('字幕规模过大：最多 20,000 条、500,000 正文字符');
    }
    cues.add(
        SubtitleCue(index: cueNumber, startMs: start, endMs: end, text: body));
  }
  if (cues.isEmpty) throw const FormatException('字幕没有有效条目');
  return cues;
}

int? _parseTime(String value, bool isVtt) {
  final m = (isVtt ? _vttTime : _srtTime).firstMatch(value);
  if (m == null) return null;
  final hours = int.parse(m.group(1) ?? '0');
  final minutes = int.parse(m.group(2)!);
  final seconds = int.parse(m.group(3)!);
  if (minutes > 59 || seconds > 59) return null;
  return hours * 3600000 +
      minutes * 60000 +
      seconds * 1000 +
      int.parse(m.group(4)!);
}

class RetimedSubtitles {
  const RetimedSubtitles(this.text, this.cueCount, this.stats);
  final String text;
  final int cueCount;
  final Map<String, Object?> stats;
}

/// ASR emissions and segment timestamps are approximate speech timings, not
/// forced alignment. Only unambiguous monotonic text matches become anchors;
/// unmatched cues are estimated inside bounded anchor gaps or left untouched.
Future<RetimedSubtitles> retimeSubtitles(List<SubtitleCue> subtitles,
        TranscribeOutcome transcription, SubtitleFormat format,
        {TranscribeCancellation? cancellation}) =>
    cancellableCompute(
        _retimingTask(subtitles, transcription, format), cancellation);

RetimedSubtitles Function() _retimingTask(List<SubtitleCue> subtitles,
        TranscribeOutcome transcription, SubtitleFormat format) =>
    () => _retime(subtitles, transcription, format);

String _normalize(String text) {
  final plain = text
      .replaceAll(_tags, '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .toLowerCase();
  final out = StringBuffer();
  for (final rune in plain.runes) {
    final folded = AudioTextNormalizer.foldCodePoint(rune);
    if (folded >= 0) {
      out.writeCharCode(folded);
    } else {
      // Preserve every language offered by the ASR engines, including accents
      // and combining marks. The book normalizer's Japanese whitelist alone
      // would erase Cyrillic, Hangul, Arabic and other scripts.
      final character = String.fromCharCode(rune);
      if (_unicodeText.hasMatch(character)) out.write(character);
    }
  }
  return out.toString();
}

void _validateCues(List<SubtitleCue> cues, {required bool input}) {
  var textLength = 0;
  if (input && cues.isEmpty) throw const FormatException('字幕没有有效条目');
  for (final cue in cues) {
    textLength += cue.text.length;
    if (cue.startMs < 0 ||
        cue.endMs <= cue.startMs ||
        cue.endMs > 360000000000 ||
        (input && cue.text.trim().isEmpty)) {
      throw const FormatException('字幕包含无效的正文或起止时间');
    }
    if (cue.text.length > _maxCueLength) {
      throw const FormatException('单条字幕正文过长');
    }
  }
  if (cues.length > _maxCues || textLength > _maxTextLength) {
    throw const FormatException('字幕或转录规模过大：最多 20,000 条、500,000 正文字符');
  }
}

RetimedSubtitles _retime(List<SubtitleCue> subtitles,
    TranscribeOutcome transcription, SubtitleFormat format) {
  final watch = Stopwatch()..start();
  _validateCues(subtitles, input: true);
  _validateCues(transcription.cues, input: false);
  final timeline = _Timeline(transcription);
  final index = _TextIndex(timeline.text);
  final normalized =
      subtitles.map((cue) => _normalize(subtitleSpeechText(cue.text))).toList();
  final frequencies = <String, int>{};
  for (final text in normalized) {
    frequencies.update(text, (count) => count + 1, ifAbsent: () => 1);
  }
  final options = <List<_Anchor>>[];
  final clockAnchors = <SubtitleClockAnchor>[];
  var missingBoundaries = 0;
  for (var i = 0; i < subtitles.length; i++) {
    final text = normalized[i];
    final anchors = <_Anchor>[];
    // Short/common responses and repeated subtitle bodies do not establish
    // identity, even when their text occurs only once in the ASR transcript.
    if (text.length >= 6 && frequencies[text] == 1) {
      final spans = index.matches(text);
      final clockAnchor =
          _clockAnchorForCue(subtitles[i], i + 1, text, spans, timeline, index);
      if (clockAnchor != null) clockAnchors.add(clockAnchor);
      for (final span in spans) {
        final start = timeline.starts[span.from];
        final end = timeline.ends[span.to];
        if (start == null || end == null || end <= start) {
          missingBoundaries++;
          continue;
        }
        anchors.add(_Anchor(i, span.from, span.to, start, end, text.length));
      }
      // Missing timing at another textual occurrence does not make the first
      // occurrence unique. Retain ambiguity instead of creating false anchors.
      if (anchors.length != spans.length) anchors.clear();
    }
    options.add(anchors);
  }
  var anchors = _monotonicChain([
    for (final candidates in options)
      if (candidates.length == 1) candidates.single,
  ], timeline.text.length);
  // A repeated ASR phrase can be disambiguated by two already reliable text
  // neighbors. Never guess between repeated phrases using the inaccurate axis.
  final contextual = <_Anchor>[];
  for (var a = 1; a < anchors.length; a++) {
    final left = anchors[a - 1];
    final right = anchors[a];
    for (var i = left.cue + 1; i < right.cue; i++) {
      if (options[i].length < 2) continue;
      final bounded = options[i].where((candidate) =>
          candidate.from >= left.to && candidate.to <= right.from);
      if (bounded.length == 1) contextual.add(bounded.single);
    }
  }
  if (contextual.isNotEmpty) {
    anchors = _monotonicChain(
        [...anchors, ...contextual]..sort((a, b) => a.cue.compareTo(b.cue)),
        timeline.text.length);
  }
  final corrected = <int, (int, int)>{
    for (final anchor in anchors) anchor.cue: (anchor.startMs, anchor.endMs),
  };
  var interpolated = 0;
  final estimatedPositions = <int>[];
  for (var a = 1; a < anchors.length; a++) {
    final left = anchors[a - 1];
    final right = anchors[a];
    final oldStart = subtitles[left.cue].endMs;
    final oldEnd = subtitles[right.cue].startMs;
    final oldGap = oldEnd - oldStart;
    final newGap = right.startMs - left.endMs;
    // Long gaps, cuts, overlapping source cues and extreme stretch do not
    // justify a local clock estimate. No extrapolation beyond the anchors.
    if (oldGap <= 0 ||
        oldGap > 120000 ||
        newGap <= 0 ||
        newGap > 120000 ||
        newGap / oldGap < 0.5 ||
        newGap / oldGap > 2) {
      continue;
    }
    int mapTime(int time) =>
        left.endMs + ((time - oldStart) * newGap / oldGap).round();
    for (var i = left.cue + 1; i < right.cue; i++) {
      final cue = subtitles[i];
      if (cue.startMs < oldStart || cue.endMs > oldEnd) continue;
      final start = mapTime(cue.startMs);
      final end = mapTime(cue.endMs);
      if (end <= start) continue;
      corrected[i] = (start, end);
      interpolated++;
      estimatedPositions.add(i + 1);
    }
  }
  // Broadcast subtitles and ASR often split the same dialogue differently.
  // One known speech boundary can support a local clock alongside independent
  // neighboring cues; it cannot justify inventing the other boundary alone.
  final clock = fitSubtitleClock(clockAnchors);
  var matchedCount = anchors.length;
  if (clock != null) {
    final directlyMatched = anchors.map((a) => a.cue).toSet();
    corrected.clear();
    estimatedPositions.clear();
    interpolated = 0;
    matchedCount = 0;
    for (var i = 0; i < subtitles.length; i++) {
      final cue = subtitles[i];
      final timing = clock.mapCue(cue.startMs, cue.endMs);
      if (timing == null) continue;
      corrected[i] = timing;
      if (directlyMatched.contains(i)) {
        matchedCount++;
      } else {
        interpolated++;
        estimatedPositions.add(i + 1);
      }
    }
  }
  final output = <SubtitleCue>[
    for (var i = 0; i < subtitles.length; i++)
      SubtitleCue(
          index: subtitles[i].index,
          startMs: corrected[i]?.$1 ?? subtitles[i].startMs,
          endMs: corrected[i]?.$2 ?? subtitles[i].endMs,
          text: subtitles[i].text),
  ];
  final unchangedPositions = <int>[
    for (var i = 0; i < subtitles.length; i++)
      if (!corrected.containsKey(i)) i + 1,
  ];
  final conflictPositions = <int>[];
  var overlappingPairs = 0;
  var outOfOrderPairs = 0;
  var newTimingConflicts = 0;
  bool overlaps(SubtitleCue a, SubtitleCue b) =>
      math.min(a.endMs, b.endMs) > math.max(a.startMs, b.startMs);
  for (var i = 1; i < output.length; i++) {
    final reversed = output[i - 1].startMs > output[i].startMs;
    final overlap = overlaps(output[i - 1], output[i]);
    if (reversed) outOfOrderPairs++;
    if (overlap) overlappingPairs++;
    if (reversed || overlap) {
      conflictPositions.add(i + 1);
      if (subtitles[i - 1].startMs <= subtitles[i].startMs &&
          !overlaps(subtitles[i - 1], subtitles[i])) {
        newTimingConflicts++;
      }
    }
  }
  String positions(List<int> values) =>
      '${values.take(10).map((i) => '#$i').join('、')}${values.length > 10 ? '…' : ''}';
  final shifts = [
    for (final entry in corrected.entries)
      entry.value.$1 - subtitles[entry.key].startMs,
  ]..sort();
  final median = shifts.isEmpty
      ? 0
      : shifts.length.isOdd
          ? shifts[shifts.length ~/ 2]
          : ((shifts[shifts.length ~/ 2 - 1] + shifts[shifts.length ~/ 2]) / 2)
              .round();
  final unchanged = subtitles.length - corrected.length;
  watch.stop();
  return RetimedSubtitles(renderSubtitles(output, format), output.length, {
    'inputCues': subtitles.length,
    'matchedCues': matchedCount,
    'interpolatedCues': interpolated,
    'unchangedCues': unchanged,
    'matchRate': matchedCount / subtitles.length,
    'medianShiftMs': median,
    'elapsedMs': watch.elapsedMilliseconds,
    'interpolatedCuePositions': estimatedPositions.take(10).toList(),
    'unchangedCuePositions': unchangedPositions.take(10).toList(),
    'conflictCuePositions': conflictPositions.take(10).toList(),
    'overlappingPairs': overlappingPairs,
    'outOfOrderPairs': outOfOrderPairs,
    'newTimingConflicts': newTimingConflicts,
    if (clock != null) 'clock': clock.toStats(),
    'timingMode': clock != null
        ? 'asr-clock'
        : timeline.tokenBoundaries > 0
            ? 'asr-token-anchors'
            : 'asr-segment-anchors',
    'warnings': <String>[
      '对轴依据 ASR 文本与时间戳，不是强制对齐；请试听检查修正结果。',
      if (corrected.isEmpty) '未找到可信的文本与时间锚点，所有字幕保留原轴。请检查语言、字幕版本与媒体范围。',
      if (clock != null)
        '已利用 ${clock.acceptedCueCount} 条字幕的语音边界分段校准时间，允许字幕和识别结果采用不同分句；估算时间仍需试听复核。',
      if (interpolated > 0)
        '$interpolated 条字幕未直接匹配，已按相邻锚点估算时间，请重点复核条目 ${positions(estimatedPositions)}。',
      if (unchanged > 0 && corrected.isNotEmpty)
        '$unchanged 条字幕缺少可靠映射，保留原轴，可能仍不准确：条目 ${positions(unchangedPositions)}。',
      if (conflictPositions.isNotEmpty)
        '结果含 $overlappingPairs 处相邻字幕重叠、$outOfOrderPairs 处起点逆序（其中 $newTimingConflicts 处为本次修正后出现）；请检查条目 ${positions(conflictPositions)} 与其前一条。已保留全部原文与条目顺序。',
      if (timeline.tokenBoundaries == 0) '转录没有可用的逐词时间戳，仅使用 ASR 片段边界。',
      if (missingBoundaries > 0) '部分文字匹配缺少对应的 ASR 边界，未按字数分配时间。',
      if (index.budgetExhausted) '已达到模糊匹配计算上限，后续仅使用精确文本锚点。',
    ],
  });
}

SubtitleClockAnchor? _clockAnchorForCue(SubtitleCue cue, int position,
    String text, List<_Span> spans, _Timeline timeline, _TextIndex index) {
  if (spans.length > 1) return null;
  int? start;
  int? end;
  if (spans.length == 1) {
    start = timeline.starts[spans.single.from];
    end = timeline.ends[spans.single.to];
  }
  // Long exact prefixes/suffixes provide real segment endpoints even when a
  // character elsewhere was misrecognized. Check uniqueness in the complete
  // transcript, before considering whether an occurrence has timing data.
  if (text.length >= 12 && text.length <= 320) {
    int? unique(String fragment) {
      final at = timeline.text.indexOf(fragment);
      if (at < 0 || timeline.text.indexOf(fragment, at + 1) >= 0) return null;
      return at;
    }

    bool contextMatches(int boundary, {required bool atStart}) {
      // A common exact phrase does not identify the surrounding dialogue.
      // Require >=85% agreement for the complete cue near this endpoint too.
      final limit = math.min(8, (text.length * 0.15).floor());
      final from =
          atStart ? boundary : math.max(0, boundary - text.length - limit);
      final to = atStart
          ? math.min(timeline.text.length, boundary + text.length + limit)
          : boundary;
      final cells = text.length * (to - from);
      if (cells > index.remainingCells) {
        index.remainingCells = 0;
        return false;
      }
      index.remainingCells -= cells;
      final match =
          _approximate(text, timeline.text.substring(from, to), limit);
      return match != null &&
          (atStart ? match.from == 0 : match.to == to - from);
    }

    if (start == null) {
      final from = unique(text.substring(0, 12));
      if (from != null &&
          timeline.starts.containsKey(from) &&
          contextMatches(from, atStart: true)) {
        start = timeline.starts[from];
      }
    }
    if (end == null) {
      final from = unique(text.substring(text.length - 12));
      if (from != null &&
          timeline.ends.containsKey(from + 12) &&
          contextMatches(from + 12, atStart: false)) {
        end = timeline.ends[from + 12];
      }
    }
  }
  // Prefer starts: an ASR segment end can include trailing silence. Each cue
  // contributes one independent clock observation, not two correlated votes.
  if (start != null) {
    return SubtitleClockAnchor(
        sourceMs: cue.startMs, targetMs: start, cuePosition: position);
  }
  if (end != null) {
    return SubtitleClockAnchor(
        sourceMs: cue.endMs, targetMs: end, cuePosition: position);
  }
  return null;
}

class _Span {
  const _Span(this.from, this.to);
  final int from;
  final int to;
}

class _Anchor extends _Span {
  const _Anchor(
      this.cue, super.from, super.to, this.startMs, this.endMs, this.weight);
  final int cue;
  final int startMs;
  final int endMs;
  final int weight;
}

/// Only known segment/token boundaries are addressable. Characters inside one
/// token deliberately have no timestamp; no uniform speech rate is invented.
class _Timeline {
  _Timeline(TranscribeOutcome original) {
    final textParts = <String>[];
    var offset = 0;
    var previousStart = -1;
    for (var i = 0; i < original.cues.length; i++) {
      final cue = original.cues[i];
      if (cue.startMs < previousStart) {
        throw const FormatException('ASR 转录的时间轴顺序无效');
      }
      previousStart = cue.startMs;
      final normalized = _normalize(cue.text);
      if (normalized.isEmpty) continue;
      textParts.add(normalized);
      final timing = original.tokenTimings?.length == original.cues.length
          ? original.tokenTimings![i]
          : null;
      if (timing != null) _addTokens(cue, timing, normalized, offset);
      starts[offset] = cue.startMs;
      ends[offset + normalized.length] = cue.endMs;
      offset += normalized.length;
    }
    text = textParts.join();
  }

  late final String text;
  final starts = <int, int>{};
  final ends = <int, int>{};
  var tokenBoundaries = 0;

  void _addTokens(SubtitleCue cue, AsrCueTokenTiming timing, String normalized,
      int offset) {
    if (timing.tokens.length != timing.offsetsMs.length || timing.isEmpty) {
      return;
    }
    final tokens = timing.tokens.map(_normalize).toList();
    if (tokens.join() != normalized) return;
    var previous = cue.startMs;
    final times = <int>[];
    for (final relative in timing.offsetsMs) {
      final time = (cue.startMs + relative).clamp(cue.startMs, cue.endMs);
      if (time < previous) return;
      times.add(time);
      previous = time;
    }
    var cursor = offset;
    for (var i = 0; i < tokens.length; i++) {
      if (tokens[i].isEmpty) continue;
      starts[cursor] = times[i];
      if (cursor > offset) ends[cursor] = times[i];
      cursor += tokens[i].length;
      tokenBoundaries++;
    }
  }
}

/// Weighted increasing non-overlapping text intervals, O(cues log textLength).
/// This prevents a later phrase from pulling an earlier cue backwards.
List<_Anchor> _monotonicChain(List<_Anchor> anchors, int length) {
  if (anchors.isEmpty) return [];
  final best = List<int>.filled(length + 2, -1);
  final score = List<int>.filled(anchors.length, 0);
  final parent = List<int>.filled(anchors.length, -1);
  var winner = -1;
  for (var i = 0; i < anchors.length; i++) {
    var previous = -1;
    for (var p = anchors[i].from + 1; p > 0; p -= p & -p) {
      if (best[p] >= 0 && (previous < 0 || score[best[p]] > score[previous])) {
        previous = best[p];
      }
    }
    parent[i] = previous;
    score[i] =
        (previous < 0 ? 0 : score[previous]) + math.min(anchors[i].weight, 80);
    for (var p = anchors[i].to + 1; p < best.length; p += p & -p) {
      if (best[p] < 0 || score[i] > score[best[p]]) best[p] = i;
    }
    if (winner < 0 || score[i] > score[winner]) winner = i;
  }
  final result = <_Anchor>[];
  for (var i = winner; i >= 0; i = parent[i]) {
    result.add(anchors[i]);
  }
  return result.reversed.toList();
}

class _TextIndex {
  _TextIndex(this.text) {
    for (var i = 0; i <= text.length - _gramSize; i++) {
      final gram = text.substring(i, i + _gramSize);
      final positions = grams.putIfAbsent(gram, () => []);
      // Saturated grams cannot establish a unique anchor; retaining one extra
      // entry distinguishes them from complete occurrence lists.
      if (positions.length <= _maxOccurrences) positions.add(i);
    }
  }
  final String text;
  final grams = <String, List<int>>{};
  var remainingCells = 12000000;
  bool get budgetExhausted => remainingCells <= 0;

  List<_Span> matches(String needle) {
    final seeds = <(int, List<int>)>[];
    var saturated = false;
    for (var i = 0; i <= needle.length - _gramSize; i++) {
      final positions = grams[needle.substring(i, i + _gramSize)];
      if (positions != null && positions.length <= _maxOccurrences) {
        seeds.add((i, positions));
      } else if (positions != null) {
        saturated = true;
      }
    }
    if (seeds.isEmpty) return [];
    seeds.sort((a, b) => a.$2.length.compareTo(b.$2.length));
    final exact = <_Span>[];
    for (final position in seeds.first.$2) {
      final from = position - seeds.first.$1;
      if (from >= 0 && text.startsWith(needle, from)) {
        exact.add(_Span(from, from + needle.length));
      }
    }
    if (exact.isNotEmpty) return exact;
    // Fuzzy anchors need substantial distinct text and >= 92% similarity.
    // Bound both the per-cue matrix and the total request computation.
    if (needle.length < 12 ||
        needle.length > 320 ||
        budgetExhausted ||
        saturated) {
      return [];
    }
    final limit = math.min(8, (needle.length * 0.08).floor());
    final votes = <int, int>{};
    // Inspect every unsaturated seed, not just the rarest prefix: a second
    // qualifying occurrence may differ at the prefix and agree everywhere else.
    // Saturation or incomplete candidate exploration disables fuzzy anchoring.
    for (final seed in seeds) {
      for (final position in seed.$2) {
        final origin = position - seed.$1;
        votes.update(origin, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final candidates = votes.entries.where((e) => e.value >= 2).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final tried = <int>[];
    final found = <_Span>[];
    for (final candidate in candidates) {
      final origin = candidate.key;
      if (tried.any((other) => (origin - other).abs() <= limit * 2)) continue;
      if (tried.length >= 6) return [];
      tried.add(origin);
      final from = math.max(0, origin - limit);
      final to = math.min(text.length, origin + needle.length + limit * 2);
      if (to <= from) continue;
      final cells = needle.length * (to - from);
      if (cells > remainingCells) {
        remainingCells = 0;
        return [];
      }
      remainingCells -= cells;
      final match = _approximate(needle, text.substring(from, to), limit);
      if (match != null) {
        final span = _Span(match.from + from, match.to + from);
        if (found
            .every((other) => span.to <= other.from || span.from >= other.to)) {
          found.add(span);
        }
      }
    }
    return found;
  }
}

/// Semi-global edit distance with free transcript prefix/suffix. Keep start
/// positions alongside scores instead of storing an unbounded traceback matrix.
_Span? _approximate(String needle, String window, int limit) {
  var row = List<int>.filled(window.length + 1, 0);
  var starts = List<int>.generate(window.length + 1, (i) => i);
  for (var i = 1; i <= needle.length; i++) {
    final next = List<int>.filled(window.length + 1, i);
    final nextStarts = List<int>.filled(window.length + 1, 0);
    for (var j = 1; j <= window.length; j++) {
      var cost = row[j - 1] +
          (needle.codeUnitAt(i - 1) == window.codeUnitAt(j - 1) ? 0 : 1);
      var start = starts[j - 1];
      if (row[j] + 1 < cost) {
        cost = row[j] + 1;
        start = starts[j];
      }
      if (next[j - 1] + 1 < cost) {
        cost = next[j - 1] + 1;
        start = nextStarts[j - 1];
      }
      next[j] = cost;
      nextStarts[j] = start;
    }
    row = next;
    starts = nextStarts;
  }
  var end = 0;
  for (var j = 1; j < row.length; j++) {
    if (row[j] < row[end]) end = j;
  }
  return row[end] <= limit && end > starts[end]
      ? _Span(starts[end], end)
      : null;
}
