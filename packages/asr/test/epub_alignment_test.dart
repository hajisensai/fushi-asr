import 'package:fushi_asr/asr.dart';
import 'package:fushi_asr_align/asr_align.dart';
import 'package:test/test.dart';

void main() {
  test(
      'replaces matched text with book punctuation, preserves unmatched text and native timings',
      () async {
    final book = EpubBook(title: 'Example', language: 'ja', sections: [
      EpubSection(index: 0, href: 'ch.xhtml', text: '今日はいい天気ですね。明日は学校へ行きます。')
    ]);
    final original = TranscribeOutcome(
        text: 'unused',
        cues: [
          SubtitleCue(index: 1, startMs: 100, endMs: 2000, text: '今日はいい天気ですね'),
          SubtitleCue(
              index: 2, startMs: 2200, endMs: 3200, text: 'XXXXXXXXXXXXXXXX'),
        ],
        elapsed: Duration.zero,
        audioMs: 4000,
        engine: 'apple-speechtranscriber');
    final aligned =
        await alignTranscriptionWithBook(book, original, SubtitleFormat.srt);
    final cues = parseSrt(aligned.text);
    expect(cues.first.text, '今日はいい天気ですね。');
    expect(cues.first.startMs, 100);
    expect(cues.first.endMs, 2000);
    expect(cues.last.text, 'XXXXXXXXXXXXXXXX');
    expect(aligned.stats['matchedCues'], 1);
    expect(aligned.stats['unmatchedCues'], 1);
    expect(aligned.stats['timingMode'], 'segment-preserved');
    expect(original.cues.first.text, '今日はいい天気ですね');
  });
}
