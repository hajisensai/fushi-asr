import 'dart:convert';

import 'package:asr/asr.dart';
import 'package:test/test.dart';

const String _srt = '''
1
00:00:00,000 --> 00:00:01,946
今日はいい天気ですね

2
00:01:02,500 --> 00:01:05,000
二行目
第二行

''';

void main() {
  group('parseSrt', () {
    test('解析出时间轴与多行正文', () {
      final List<SubtitleCue> cues = parseSrt(_srt);
      expect(cues, hasLength(2));
      expect(cues[0].startMs, 0);
      expect(cues[0].endMs, 1946);
      expect(cues[0].text, '今日はいい天気ですね');
      expect(cues[1].startMs, 62500);
      expect(cues[1].endMs, 65000);
      expect(cues[1].text, '二行目\n第二行');
    });

    test('毫秒分隔符逗号 / 点号都吃', () {
      // 宽松是有意的：这个函数也要能读用户手上的旧字幕，不只读我们自己的产物。
      final List<SubtitleCue> dot =
          parseSrt('1\n00:00:01.500 --> 00:00:02.000\nx\n');
      expect(dot.single.startMs, 1500);
    });

    test('缺序号行也能解析，序号自动补', () {
      final List<SubtitleCue> cues =
          parseSrt('00:00:00,000 --> 00:00:01,000\na\n\n'
              '00:00:01,000 --> 00:00:02,000\nb\n');
      expect(cues.map((SubtitleCue c) => c.index), <int>[1, 2]);
      expect(cues.map((SubtitleCue c) => c.text), <String>['a', 'b']);
    });

    test('一处畸形不会吃掉整份文件', () {
      // 判据是"后面的还在"，不是"不抛异常"——静默丢掉半份字幕比抛错更糟。
      final List<SubtitleCue> cues = parseSrt('这行是垃圾\n\n'
          '1\n00:00:00,000 --> 00:00:01,000\nok\n');
      expect(cues.single.text, 'ok');
    });

    test('空输入 → 空列表', () {
      expect(parseSrt(''), isEmpty);
      expect(parseSrt('\n\n  \n'), isEmpty);
    });
  });

  group('renderSubtitles', () {
    final List<SubtitleCue> cues = parseSrt(_srt);

    test('SRT 往返：解析再渲染，时间轴与正文不变', () {
      final List<SubtitleCue> back =
          parseSrt(renderSubtitles(cues, SubtitleFormat.srt));
      expect(back.length, cues.length);
      for (int i = 0; i < cues.length; i++) {
        expect(back[i].startMs, cues[i].startMs);
        expect(back[i].endMs, cues[i].endMs);
        expect(back[i].text, cues[i].text);
      }
    });

    test('VTT：带头、毫秒用点号', () {
      final String vtt = renderSubtitles(cues, SubtitleFormat.vtt);
      expect(vtt, startsWith('WEBVTT\n\n'));
      expect(vtt, contains('00:00:00.000 --> 00:00:01.946'));
      expect(vtt, isNot(contains(',946')));
      expect(vtt, contains('今日はいい天気ですね'));
    });

    test('JSON：毫秒是整数，正文原样', () {
      final Object? json =
          jsonDecode(renderSubtitles(cues, SubtitleFormat.json));
      final List<Object?> list =
          (json! as Map<String, Object?>)['cues']! as List<Object?>;
      expect(list, hasLength(2));
      final Map<String, Object?> first = list.first! as Map<String, Object?>;
      expect(first['startMs'], 0);
      expect(first['endMs'], 1946);
      expect(first['text'], '今日はいい天気ですね');
    });

    test('小时进位正确（超过一小时的素材）', () {
      final String out = renderSubtitles(
        <SubtitleCue>[
          const SubtitleCue(
            index: 1,
            startMs: 3661234,
            endMs: 3662000,
            text: 'x',
          ),
        ],
        SubtitleFormat.srt,
      );
      expect(out, contains('01:01:01,234 --> 01:01:02,000'));
    });
  });

  test('SubtitleFormat.fromName 认得三种，其余为 null', () {
    expect(SubtitleFormat.fromName('srt'), SubtitleFormat.srt);
    expect(SubtitleFormat.fromName('vtt'), SubtitleFormat.vtt);
    expect(SubtitleFormat.fromName('json'), SubtitleFormat.json);
    expect(SubtitleFormat.fromName('ass'), isNull);
  });
}
