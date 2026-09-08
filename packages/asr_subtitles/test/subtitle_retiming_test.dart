import 'dart:convert';

import 'package:fushi_asr_core/asr_core.dart' show AsrCueTokenTiming;
import 'package:fushi_asr_subtitles/asr_subtitles.dart';
import 'package:test/test.dart';

SubtitleCue cue(String text, int start, int end, {int index = 1}) =>
    SubtitleCue(index: index, startMs: start, endMs: end, text: text);

class _Transcription implements RetimingTranscription {
  const _Transcription(this.cues, this.tokenTimings);

  @override
  final List<SubtitleCue> cues;

  @override
  final List<AsrCueTokenTiming>? tokenTimings;
}

RetimingTranscription asr(List<SubtitleCue> cues,
        {List<AsrCueTokenTiming>? tokens}) =>
    _Transcription(cues, tokens);

void main() {
  group('parseRetimingSubtitles', () {
    test('preserves SRT multiline text, markup, BOM and CRLF', () {
      final parsed = parseRetimingSubtitles('\uFEFF7\r\n'
          '00:00:01,250 --> 00:00:04,500\r\n'
          '<i>今日はいい天気ですね。</i>\r\n  二行目です。  \r\n\r\n'
          '9\r\n00:00:05,000 --> 00:00:06,000\r\nはい。\r\n');
      expect(parsed, hasLength(2));
      expect(parsed.first.startMs, 1250);
      expect(parsed.first.endMs, 4500);
      expect(parsed.first.text, '<i>今日はいい天気ですね。</i>\n  二行目です。  ');
      expect(parsed.last.text, 'はい。');
    });

    test('reads WebVTT short times, identifiers, settings and metadata blocks',
        () {
      final parsed = parseRetimingSubtitles('WEBVTT Example\nLanguage: ja\n\n'
          'NOTE A comment\nnot a cue\n\nSTYLE\n::cue { color: lime; }\n\n'
          'REGION\nid:bottom\n\n'
          'first-cue\n00:10.000 --> 00:12.500 align:start line:90%\n'
          '<v 山田>今日はいい天気ですね。</v>\n\n'
          '01:02:03.000 --> 01:02:04.000\n二行目\n');
      expect(parsed, hasLength(2));
      expect(parsed.first.startMs, 10000);
      expect(parsed.first.endMs, 12500);
      expect(parsed.first.text, '<v 山田>今日はいい天気ですね。</v>');
      expect(parsed.last.startMs, 3723000);
    });

    test('supports SRT without sequence numbers and overlapping cues', () {
      final parsed =
          parseRetimingSubtitles('00:00:02,000 --> 00:00:04,000\nfirst\n\n'
              '00:00:03.000 --> 00:00:05.000\nsecond\n');
      expect(parsed, hasLength(2));
      expect(parsed.last.startMs, 3000);
    });

    for (final input in <String>[
      '',
      ' \n\n',
      'not subtitles',
      'WEBVTT\n\nNOTE only comments\n',
      'WEBVTT\n00:01.000 --> 00:02.000\nmissing header separator',
      '1\n00:61:01,000 --> 00:62:02,000\ninvalid minutes',
      '1\n00:00:61,000 --> 00:01:03,000\ninvalid seconds',
      '1\n00:00:01,000 --> 00:00:01,000\nzero length',
      '1\n00:00:02,000 --> 00:00:01,000\nbackwards',
      '1\n-00:00:02,000 --> 00:00:01,000\nnegative',
      '1\n00:00:01,00 --> 00:00:02,000\nbad milliseconds',
      '1\n00:00:01,000 --> 00:00:02,000\n',
      '1\n00:00:01,000 --> 00:00:02,000 garbage\ninvalid suffix',
      '1\n00:00:01,000 --> 00:00:02,000\ntext\n'
          '2\n00:00:02,000 --> 00:00:03,000\nmissing blank line',
      '1\n00:00:01,000 --> 00:00:02,000\ntext\n\nbroken next cue',
      'WEBVTT\n\n00:01.000 --> 00:02.000 invalid-setting\ntext',
      '1\n00:00:01,000 --> 00:00:02,000\n\u0000',
    ]) {
      test('rejects malformed input ${jsonEncode(input)}', () {
        expect(() => parseRetimingSubtitles(input), throwsFormatException);
      });
    }

    test('enforces upload bytes and practical cue/text bounds', () {
      expect(() => parseRetimingSubtitles('あ' * (maxSubtitleBytes ~/ 3 + 1)),
          throwsFormatException);
      expect(
          () => parseRetimingSubtitles(
              '1\n00:00:01,000 --> 00:00:02,000\n${'a' * 8193}'),
          throwsFormatException);
      expect(
          () => parseRetimingSubtitles(
              '00:00:01,000 --> 00:00:02,000\nx\n\n' * 20001),
          throwsFormatException);
      expect(
          () => parseRetimingSubtitles(
              '00:00:01,000 --> 00:00:02,000\n${'x' * 5000}\n\n' * 101),
          throwsFormatException);
    });
  });

  group('retimeSubtitles', () {
    test('uses independent one-sided boundaries when ASR merges broadcast cues',
        () async {
      const phrases = [
        '今日は図書館で新しい本を読みます。',
        '明日は公園で友人たちと遊びます。',
        '来週の予定について話し合いましょう。',
        '電車に乗って海辺の町へ向かいます。',
        '美しい景色を写真に残したいです。',
        '夕方になったら家へ帰りましょう。',
      ];
      final input = [
        for (var i = 0; i < phrases.length; i++)
          cue('（話者）${phrases[i]}', 10000 + i * 3000, 12000 + i * 3000)
      ];
      final recognized = [
        for (var i = 0; i < phrases.length; i += 2)
          cue(phrases[i] + phrases[i + 1], input[i].startMs + 5000,
              input[i + 1].endMs + 5000)
      ];
      final result =
          await retimeSubtitles(input, asr(recognized), SubtitleFormat.srt);
      final output = parseSrt(result.text);
      expect(result.stats['timingMode'], 'asr-clock');
      expect(result.stats['unchangedCues'], 0);
      expect(result.stats['newTimingConflicts'], 0);
      expect(output.map((c) => c.text), input.map((c) => c.text));
      expect(output.map((c) => c.startMs), input.map((c) => c.startMs + 5000));
      expect(output.map((c) => c.endMs), input.map((c) => c.endMs + 5000));
    });

    test('one shared ASR prefix cannot become independent clock observations',
        () async {
      final input = [
        cue('This sentence has the first completely distinct continuation.',
            10000, 10500),
        cue('This sentence goes into a second wholly different ending.', 11000,
            11500),
        cue('This sentence tells a third absolutely separate story.', 12000,
            12500),
        cue('This sentence concludes with the fourth unrelated idea.', 13000,
            13500),
        cue('There is no actual speech for this subtitle.', 20000, 21000),
      ];
      final result = await retimeSubtitles(
          input,
          asr([
            cue('This sentence will be spoken only once in the entire recording.',
                100000, 104000)
          ]),
          SubtitleFormat.srt);
      expect(result.stats['matchedCues'], 0);
      expect(result.stats['interpolatedCues'], 0);
      expect(result.stats['unchangedCues'], input.length);
      expect(parseSrt(result.text).map((c) => c.startMs),
          input.map((c) => c.startMs));
    });

    test('repairs a global offset, preserving text, order and count', () async {
      final input = [
        cue('<i>今日はいい天気ですね。</i>', 1000, 3000),
        cue('明日は図書館で\n本を読みます。', 4000, 6000),
      ];
      final result = await retimeSubtitles(
          input,
          asr([
            cue('今日はいい天気ですね', 6000, 8000),
            cue('明日は図書館で本を読みます', 9000, 11000),
          ]),
          SubtitleFormat.srt);
      final output = parseSrt(result.text);
      expect(output.map((c) => c.text), input.map((c) => c.text));
      expect(output.map((c) => c.startMs), [6000, 9000]);
      expect(output.map((c) => c.endMs), [8000, 11000]);
      expect(result.cueCount, 2);
      expect(result.stats['matchedCues'], 2);
      expect(result.stats['interpolatedCues'], 0);
      expect(result.stats['unchangedCues'], 0);
      expect(result.stats['medianShiftMs'], 5000);
      expect(result.stats['matchRate'], 1);
      expect(input.first.startMs, 1000);
    });

    for (final phrase in [
      'Сегодня замечательная погода и мы идём гулять.',
      '오늘은 날씨가 좋아서 도서관에 갑니다.',
      'الطقس جميل اليوم وسنذهب إلى المكتبة.',
      'Demain nous étudierons à la bibliothèque.',
      'วันนี้อากาศดีมากเราจะไปห้องสมุดกัน',
    ]) {
      test('preserves Unicode when matching $phrase', () async {
        final result = await retimeSubtitles([cue(phrase, 1000, 2000)],
            asr([cue(phrase.toUpperCase(), 6000, 7000)]), SubtitleFormat.srt);
        expect(result.stats['matchedCues'], 1);
        expect(parseSrt(result.text).single.startMs, 6000);
        expect(parseSrt(result.text).single.text, phrase);
      });
    }

    test('non-Latin words are not stripped into matching Latin remnants',
        () async {
      final result = await retimeSubtitles(
          [
            cue('Сегодня test sentence', 1000, 2000),
            cue('오늘은 other sentence', 3000, 4000),
            cue('الطقس final sentence', 5000, 6000),
            cue('éééééé accent sentence', 7000, 8000),
          ],
          asr([
            cue('Вчера test sentence', 10000, 11000),
            cue('안녕하세요 other sentence', 12000, 13000),
            cue('المكتبة final sentence', 14000, 15000),
            cue('àààààà accent sentence', 16000, 17000),
          ]),
          SubtitleFormat.srt);
      expect(result.stats['matchedCues'], 0);
      expect(result.stats['unchangedCues'], 4);
    });

    test('handles negative shifts larger than the audio duration', () async {
      final result = await retimeSubtitles(
          [cue('This is the opening sentence.', 100000, 102000)],
          asr([cue('this is the opening sentence', 1000, 3000)]),
          SubtitleFormat.vtt);
      expect(parseRetimingSubtitles(result.text).single.startMs, 1000);
      expect(result.stats['medianShiftMs'], -99000);
    });

    test('maps clock drift and local gaps piecewise without replacing text',
        () async {
      final input = [
        cue('The first recognizable sentence.', 1000, 2000),
        cue('Unrecognized material here.', 3000, 4000),
        cue('A completely distinct middle anchor.', 5000, 6000),
        cue('はい', 7000, 8000),
        cue('The final recognizable sentence.', 9000, 10000),
      ];
      final result = await retimeSubtitles(
          input,
          asr([
            cue('The first recognizable sentence.', 2000, 3000),
            cue('A completely distinct middle anchor.', 7500, 8500),
            cue('The final recognizable sentence.', 10000, 11000),
          ]),
          SubtitleFormat.srt);
      final output = parseSrt(result.text);
      expect(output.map((c) => c.startMs), [2000, 4500, 7500, 9000, 10000]);
      expect(output.map((c) => c.endMs), [3000, 6000, 8500, 9500, 11000]);
      expect(output.map((c) => c.text), input.map((c) => c.text));
      expect(result.stats['matchedCues'], 3);
      expect(result.stats['interpolatedCues'], 2);
      expect(result.stats['unchangedCues'], 0);
      expect(result.stats['warnings'], contains(contains('估算')));
    });

    test('short, repeated and mismatched text cannot invent an anchor',
        () async {
      final input = [
        cue('はい', 1000, 2000),
        cue('Thank you very much', 3000, 4000),
        cue('Thank you very much', 5000, 6000),
        cue('A completely unrelated translation.', 7000, 8000),
      ];
      final result = await retimeSubtitles(
          input,
          asr([
            cue('はい', 6000, 7000),
            cue('Thank you very much', 8000, 9000),
            cue('The weather is pleasant today.', 10000, 11000),
          ]),
          SubtitleFormat.srt);
      expect(parseSrt(result.text).map((c) => c.startMs),
          [1000, 3000, 5000, 7000]);
      expect(result.stats['matchedCues'], 0);
      expect(result.stats['unchangedCues'], 4);
      expect(result.stats['warnings'], contains(contains('未找到可信')));
    });

    test('repeated ASR phrases are only resolved by surrounding text anchors',
        () async {
      final result = await retimeSubtitles(
          [
            cue('The unique opening phrase.', 1000, 2000),
            cue('This phrase is repeated.', 3000, 4000),
            cue('The unique closing phrase.', 5000, 6000),
          ],
          asr([
            cue('This phrase is repeated.', 1000, 2000),
            cue('The unique opening phrase.', 6000, 7000),
            cue('This phrase is repeated.', 8000, 9000),
            cue('The unique closing phrase.', 10000, 11000),
            cue('This phrase is repeated.', 12000, 13000),
          ]),
          SubtitleFormat.srt);
      expect(parseSrt(result.text).map((c) => c.startMs), [6000, 8000, 10000]);
      expect(result.stats['matchedCues'], 3);
    });

    test('uses a monotonic anchor chain when phrases appear out of order',
        () async {
      final result = await retimeSubtitles(
          [
            cue('The opening phrase is recognizably long.', 1000, 2000),
            cue('Small phrase', 3000, 4000),
            cue('The ending phrase is recognizably long.', 5000, 6000),
          ],
          asr([
            cue('Small phrase', 1000, 2000),
            cue('The opening phrase is recognizably long.', 6000, 7000),
            cue('The ending phrase is recognizably long.', 10000, 11000),
          ]),
          SubtitleFormat.srt);
      expect(parseSrt(result.text).map((c) => c.startMs), [6000, 8000, 10000]);
      expect(result.stats['matchedCues'], 2);
      expect(result.stats['interpolatedCues'], 1);
    });

    test('does not extrapolate or stretch through long gaps and cuts',
        () async {
      final input = [
        cue('unmatched prefix', 0, 500),
        cue('The first unique anchor.', 1000, 2000),
        cue('unmatched inside a long gap', 3000, 4000),
        cue('The final unique anchor.', 300000, 301000),
        cue('unmatched suffix', 310000, 311000),
      ];
      final result = await retimeSubtitles(
          input,
          asr([
            cue('The first unique anchor.', 6000, 7000),
            cue('The final unique anchor.', 305000, 306000),
          ]),
          SubtitleFormat.srt);
      expect(parseSrt(result.text).map((c) => c.startMs),
          [0, 6000, 3000, 305000, 310000]);
      expect(result.stats['unchangedCues'], 3);
      expect(result.stats['interpolatedCues'], 0);
      expect(result.stats['outOfOrderPairs'], 1);
      expect(result.stats['newTimingConflicts'], 1);
      expect(result.stats['conflictCuePositions'], [3]);
      expect(result.stats['warnings'], contains(contains('起点逆序')));
      expect(result.stats['warnings'], contains(contains('#3')));
    });

    test('reports introduced overlaps with reviewable cue positions', () async {
      final result = await retimeSubtitles(
          [
            cue('The first unique anchor.', 1000, 2000),
            cue('嗯', 8000, 10000),
          ],
          asr([
            cue('The first unique anchor.', 7000, 9000),
          ]),
          SubtitleFormat.srt);
      expect(result.stats['overlappingPairs'], 1);
      expect(result.stats['newTimingConflicts'], 1);
      expect(result.stats['unchangedCuePositions'], [2]);
      expect(result.stats['conflictCuePositions'], [2]);
    });

    test('can span ASR segmentation and use actual token boundaries', () async {
      final result = await retimeSubtitles(
          [
            cue('今日は晴れです', 1000, 2000),
            cue('明日は雨です', 3000, 4000),
          ],
          asr([
            cue('今日は晴れです明日は雨です', 6000, 10000),
          ], tokens: [
            AsrCueTokenTiming(
                tokens: ['今日は', '晴れです', '明日は', '雨です'],
                offsetsMs: [100, 1000, 2000, 3000]),
          ]),
          SubtitleFormat.srt);
      final output = parseSrt(result.text);
      expect(output.map((c) => c.startMs), [6000, 8000]);
      expect(output.map((c) => c.endMs), [8000, 10000]);
      expect(result.stats['matchedCues'], 2);
      expect(result.stats['timingMode'], 'asr-token-anchors');
    });

    test('missing token boundaries never fabricate character timings',
        () async {
      final input = [
        cue('今日は晴れです', 1000, 2000),
        cue('明日は雨です', 3000, 4000),
      ];
      final result = await retimeSubtitles(
          input,
          asr([
            cue('今日は晴れです明日は雨です', 6000, 10000),
          ]),
          SubtitleFormat.srt);
      expect(parseSrt(result.text).map((c) => c.startMs), [1000, 3000]);
      expect(result.stats['matchedCues'], 0);
      expect(result.stats['warnings'], contains(contains('未按字数')));
    });

    test('ignores inconsistent token text and nonmonotonic token timing',
        () async {
      final result = await retimeSubtitles(
          [
            cue('今日は晴れです', 1000, 2000),
            cue('明日は雨です', 3000, 4000),
          ],
          asr([
            cue('今日は晴れです明日は雨です', 6000, 10000),
          ], tokens: [
            AsrCueTokenTiming(
                tokens: ['今日は晴れです', '明日は雨です'], offsetsMs: [3000, 2000]),
          ]),
          SubtitleFormat.srt);
      expect(result.stats['matchedCues'], 0);
      expect(result.stats['timingMode'], 'asr-segment-anchors');
    });

    test('accepts a small ASR error in long distinctive text', () async {
      final original = '今日は図書館に行って新しい本を読みます';
      final result = await retimeSubtitles(
          [
            cue(original, 1000, 3000),
          ],
          asr([
            cue('今日は図書館に行って新しい本を詠みます', 6000, 8000),
          ]),
          SubtitleFormat.srt);
      expect(parseSrt(result.text).single.text, original);
      expect(parseSrt(result.text).single.startMs, 6000);
      expect(result.stats['matchedCues'], 1);
    });

    test('does not choose between two similar fuzzy matches', () async {
      final result = await retimeSubtitles(
          [
            cue('今日は図書館に行って新しい本を読みます', 1000, 3000),
          ],
          asr([
            cue('今日は図書館に行って新しい本を詠みます', 6000, 8000),
            cue('今日は図書館に行って楽しい本を読みます', 10000, 12000),
          ]),
          SubtitleFormat.srt);
      expect(parseSrt(result.text).single.startMs, 1000);
      expect(result.stats['matchedCues'], 0);
    });

    test('missing timestamps at another occurrence do not imply unique text',
        () async {
      final result = await retimeSubtitles(
          [
            cue('This phrase is repeated.', 1000, 2000),
          ],
          asr([
            cue('This phrase is repeated.', 6000, 8000),
            cue('Before this phrase is repeated after.', 10000, 12000),
          ]),
          SubtitleFormat.srt);
      expect(result.stats['matchedCues'], 0);
      expect(parseSrt(result.text).single.startMs, 1000);
    });

    test('fuzzy ambiguity checks all seed positions, including the suffix',
        () async {
      const original = 'thequickbrownfoxjumpsoverthelazydogandreadsavery'
          'interestingnewspaperbeforegoingtoworkeachmorning';
      String replaceAt(String value, int index) =>
          '${value.substring(0, index)}z${value.substring(index + 1)}';
      final first = replaceAt(original, original.length - 4);
      var second = original;
      for (final index in [3, 7, 11]) {
        second = replaceAt(second, index);
      }
      final result = await retimeSubtitles(
          [
            cue(original, 1000, 2000),
          ],
          asr([
            cue(first, 6000, 8000),
            cue(second, 10000, 12000),
          ]),
          SubtitleFormat.srt);
      expect(result.stats['matchedCues'], 0);
      expect(parseSrt(result.text).single.startMs, 1000);
    });

    test('empty ASR output leaves all cue bodies and timestamps intact',
        () async {
      final result = await retimeSubtitles([
        cue('今天下午我们去公园散步。', 1000, 2000),
      ], asr([]), SubtitleFormat.json);
      final output = jsonDecode(result.text) as Map<String, dynamic>;
      expect((output['cues'] as List).single['text'], '今天下午我们去公园散步。');
      expect((output['cues'] as List).single['startMs'], 1000);
      expect(result.stats['unchangedCues'], 1);
    });

    test('validates directly supplied cue lists too', () async {
      await expectLater(retimeSubtitles([], asr([]), SubtitleFormat.srt),
          throwsFormatException);
      await expectLater(
          retimeSubtitles([cue('text', -1, 2000)], asr([]), SubtitleFormat.srt),
          throwsFormatException);
    });

    test('honors already cancelled work', () async {
      final cancellation = TranscribeCancellation()..cancel();
      await expectLater(
          retimeSubtitles([
            cue('Original sentence.', 1000, 2000)
          ], asr([]), SubtitleFormat.srt, cancellation: cancellation),
          throwsA(isA<TranscribeCancelled>()));
    });
  });
}
