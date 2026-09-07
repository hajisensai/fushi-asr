/// 字幕输出格式转换。
///
/// 转录核心只产 SRT（`AsrTranscribeResult.srtPath`）。VTT / JSON 是在它之上的
/// **纯文本变换**，放这里而不是塞进核心：核心那条链路的产物格式是它与恢复状态、
/// sidecar 对齐的一部分，不该为了多一种输出格式动它。
library;

import 'dart:convert';

/// 一条字幕。
class SubtitleCue {
  const SubtitleCue({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int index;
  final int startMs;
  final int endMs;
  final String text;

  Map<String, Object?> toJson() => <String, Object?>{
        'index': index,
        'startMs': startMs,
        'endMs': endMs,
        'text': text,
      };
}

/// 输出格式。
enum SubtitleFormat {
  srt,
  vtt,
  json;

  static SubtitleFormat? fromName(String name) {
    for (final SubtitleFormat f in values) {
      if (f.name == name) return f;
    }
    return null;
  }
}

final RegExp _timeLine = RegExp(
  r'^(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*'
  r'(\d{2}):(\d{2}):(\d{2})[,.](\d{3})',
);

/// 解析 SRT。
///
/// 刻意宽松：分隔符按空行、序号行缺失也认（有些生成器不写），时间轴的毫秒分隔
/// 逗号点号都吃。转录产物是我们自己写的，本来严格；宽松是为了这个函数也能用来
/// 读用户手上的旧字幕。
List<SubtitleCue> parseSrt(String text) {
  final List<SubtitleCue> cues = <SubtitleCue>[];
  final List<String> lines = const LineSplitter().convert(text);
  int i = 0;
  int fallbackIndex = 1;
  while (i < lines.length) {
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }
    if (i >= lines.length) break;
    int? index;
    if (!_timeLine.hasMatch(lines[i])) {
      index = int.tryParse(lines[i].trim());
      i++;
      if (i >= lines.length) break;
    }
    final RegExpMatch? m = _timeLine.firstMatch(lines[i]);
    if (m == null) {
      // 既不是序号也不是时间轴：跳过这一行，避免一处畸形吃掉整份文件。
      i++;
      continue;
    }
    i++;
    final List<String> body = <String>[];
    while (i < lines.length && lines[i].trim().isNotEmpty) {
      body.add(lines[i]);
      i++;
    }
    cues.add(SubtitleCue(
      index: index ?? fallbackIndex,
      startMs: _msFrom(m, 1),
      endMs: _msFrom(m, 5),
      text: body.join('\n'),
    ));
    fallbackIndex = cues.last.index + 1;
  }
  return cues;
}

int _msFrom(RegExpMatch m, int group) =>
    int.parse(m.group(group)!) * 3600000 +
    int.parse(m.group(group + 1)!) * 60000 +
    int.parse(m.group(group + 2)!) * 1000 +
    int.parse(m.group(group + 3)!);

String _stamp(int ms, {required String msSeparator}) {
  final int h = ms ~/ 3600000;
  final int min = (ms % 3600000) ~/ 60000;
  final int s = (ms % 60000) ~/ 1000;
  final int rest = ms % 1000;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(min)}:${two(s)}$msSeparator'
      '${rest.toString().padLeft(3, '0')}';
}

/// 按 [format] 渲染。
String renderSubtitles(List<SubtitleCue> cues, SubtitleFormat format) {
  switch (format) {
    case SubtitleFormat.srt:
      final StringBuffer b = StringBuffer();
      for (int i = 0; i < cues.length; i++) {
        final SubtitleCue c = cues[i];
        b.writeln(i + 1);
        b.writeln('${_stamp(c.startMs, msSeparator: ',')} --> '
            '${_stamp(c.endMs, msSeparator: ',')}');
        b.writeln(c.text);
        b.writeln();
      }
      return b.toString();
    case SubtitleFormat.vtt:
      final StringBuffer b = StringBuffer('WEBVTT\n\n');
      for (final SubtitleCue c in cues) {
        b.writeln('${_stamp(c.startMs, msSeparator: '.')} --> '
            '${_stamp(c.endMs, msSeparator: '.')}');
        b.writeln(c.text);
        b.writeln();
      }
      return b.toString();
    case SubtitleFormat.json:
      return '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
            'cues': <Object>[for (final SubtitleCue c in cues) c.toJson()],
          })}\n';
  }
}
