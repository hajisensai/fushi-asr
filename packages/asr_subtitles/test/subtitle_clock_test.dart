import 'package:fushi_asr_subtitles/asr_subtitles.dart';
import 'package:test/test.dart';

SubtitleClockAnchor anchor(int source, int shift, int cue) =>
    SubtitleClockAnchor(
        sourceMs: source, targetMs: source + shift, cuePosition: cue);

void main() {
  test('requires four independent cues and does not count endpoints twice', () {
    expect(
        fitSubtitleClock([
          anchor(10000, 5000, 1),
          anchor(12000, 5000, 1),
          anchor(20000, 5000, 2),
          anchor(22000, 5000, 2),
          anchor(30000, 5000, 3),
          anchor(32000, 5000, 3),
        ]),
        isNull);
    expect(fitSubtitleClock([]), isNull);
  });

  test('one reused ASR boundary cannot masquerade as independent cue evidence',
      () {
    expect(
        fitSubtitleClock([
          for (var i = 0; i < 4; i++)
            SubtitleClockAnchor(
                sourceMs: 10000 + i * 1000,
                targetMs: 100000,
                cuePosition: i + 1),
        ]),
        isNull);
    expect(
        fitSubtitleClock([
          anchor(10000, 5000, 1),
          anchor(10000, 5000, 2),
          anchor(20000, 5000, 3),
          anchor(20000, 5000, 4),
        ]),
        isNull);
  });

  test('applies a supported offset and exactly preserves durations and gaps',
      () {
    final mapping = fitSubtitleClock([
      anchor(10000, 5000, 1),
      anchor(20000, 5000, 2),
      anchor(30000, 5000, 3),
      anchor(40000, 5000, 4),
    ])!;
    expect(mapping.mapCue(13000, 14789), (18000, 19789));
    expect(mapping.mapCue(14789, 16000), (19789, 21000));
    expect(mapping.acceptedCueCount, 4);
    expect(mapping.rejectedCueCount, 0);
    expect(mapping.regionCount, 1);
  });

  test('limits extrapolation and rejects invalid input cue times', () {
    final mapping = fitSubtitleClock([
      anchor(100000, -5000, 1),
      anchor(110000, -5000, 2),
      anchor(120000, -5000, 3),
      anchor(130000, -5000, 4),
    ])!;
    expect(mapping.mapCue(70000, 71000), (65000, 66000));
    expect(mapping.mapCue(69000, 71000), isNull);
    expect(mapping.mapCue(159000, 160000), (154000, 155000));
    expect(mapping.mapCue(159000, 160001), isNull);
    expect(mapping.mapCue(-1, 1000), isNull);
    expect(mapping.mapCue(100000, 100000), isNull);
  });

  test('uses one clock for supported frame-rate drift', () {
    final mapping = fitSubtitleClock([
      for (var i = 0; i < 8; i++)
        anchor(10000 + i * 20000, 5000 + i * 800, i + 1),
    ])!;
    // target = source * 1.04 + 4600
    expect(mapping.mapCue(35000, 40000), (41000, 46200));
    expect(mapping.mapCue(40000, 45000), (46200, 51400));
  });

  test('ignores one large timing outlier in a local clock', () {
    final mapping = fitSubtitleClock([
      anchor(10000, 5000, 1),
      anchor(20000, 5000, 2),
      anchor(30000, 27000, 3),
      anchor(40000, 5000, 4),
      anchor(50000, 5000, 5),
    ])!;
    expect(mapping.mapCue(29000, 31000), (34000, 36000));
    expect(mapping.acceptedCueCount, 4);
    expect(mapping.rejectedCueCount, 1);
  });

  test('drops lone beginning and ending outliers', () {
    final mapping = fitSubtitleClock([
      anchor(10000, 27000, 1),
      anchor(20000, 5000, 2),
      anchor(30000, 5000, 3),
      anchor(40000, 5000, 4),
      anchor(50000, 5000, 5),
      anchor(60000, 27000, 6),
    ])!;
    expect(mapping.mapCue(29000, 31000), (34000, 36000));
    expect(mapping.acceptedCueCount, 4);
    expect(mapping.rejectedCueCount, 2);
  });

  test('supports a broadcast version cut without stretching speech over it',
      () {
    final mapping = fitSubtitleClock([
      anchor(20000, 0, 1),
      anchor(40000, 0, 2),
      anchor(154000, -10000, 3),
      anchor(175000, -10000, 4),
      anchor(200000, -10000, 5),
      anchor(230000, -10000, 6),
    ])!;
    expect(mapping.regionCount, 2);
    expect(mapping.mapCue(45000, 50000), (45000, 50000));
    expect(mapping.mapCue(154000, 156000), (144000, 146000));
    expect(mapping.mapCue(90000, 110000), isNull);
    expect(mapping.mapCue(60000, 160000), isNull);
  });

  test('negative clock jumps shrink domains instead of reversing cue order',
      () {
    final mapping = fitSubtitleClock([
      anchor(20000, 0, 1),
      anchor(40000, 0, 2),
      anchor(55000, -10000, 3),
      anchor(75000, -10000, 4),
    ])!;
    expect(mapping.regionCount, 2);
    expect(mapping.mapCue(39000, 40000), (39000, 40000));
    expect(mapping.mapCue(55000, 56000), (45000, 46000));
    expect(mapping.mapCue(45000, 50000), isNull);
    final accepted = <(int, int)>[];
    for (var source = 10000; source < 100000; source += 1000) {
      final target = mapping.mapCue(source, source + 1000);
      if (target != null) accepted.add(target);
    }
    for (var i = 1; i < accepted.length; i++) {
      expect(accepted[i].$1, greaterThanOrEqualTo(accepted[i - 1].$2));
    }
  });

  test('positive jumps keep order and reject cues spanning the cut', () {
    final mapping = fitSubtitleClock([
      anchor(20000, 0, 1),
      anchor(40000, 0, 2),
      anchor(55000, 10000, 3),
      anchor(75000, 10000, 4),
    ])!;
    expect(mapping.mapCue(46000, 49000), isNull);
    expect(mapping.mapCue(47500, 48500), (57500, 58500));
  });

  test('rejects contradictory clocks when too few independent cues remain', () {
    expect(
        fitSubtitleClock([
          anchor(20000, 10000, 1),
          anchor(40000, 10000, 2),
          anchor(45000, -20000, 3),
          anchor(65000, -20000, 4),
        ]),
        isNull);
  });

  test('bridges a bounded sparse same-clock gap only when shifts agree', () {
    final mapping = fitSubtitleClock([
      anchor(100000, -10000, 1),
      anchor(120000, -9800, 2),
      anchor(275000, -9500, 3),
      anchor(300000, -10000, 4),
    ])!;
    expect(mapping.regionCount, 1);
    expect(mapping.mapCue(200000, 201000), (190100, 191100));
  });

  test('does not bridge a huge gap even when both sides have the same offset',
      () {
    final mapping = fitSubtitleClock([
      anchor(100000, -10000, 1),
      anchor(120000, -10000, 2),
      anchor(400000, -10000, 3),
      anchor(420000, -10000, 4),
    ])!;
    expect(mapping.regionCount, 2);
    expect(mapping.mapCue(250000, 251000), isNull);
  });

  test('does not infer a clock from coincident boundaries alone', () {
    expect(
        fitSubtitleClock([
          anchor(100000, 5000, 1),
          anchor(100000, 5000, 2),
          anchor(100000, 5000, 3),
          anchor(100000, 5000, 4),
        ]),
        isNull);
  });

  test('moderate ASR boundary jitter does not introduce artificial drift', () {
    final mapping = fitSubtitleClock([
      anchor(100000, -10000, 1),
      anchor(130000, -9000, 2),
      anchor(160000, -9900, 3),
      anchor(190000, -9400, 4),
      anchor(220000, -10100, 5),
      anchor(250000, -9500, 6),
    ])!;
    final value = mapping.mapCue(150000, 152345)!;
    expect(value.$2 - value.$1, 2345);
    expect(value.$1 - 150000, inInclusiveRange(-10100, -9000));
  });

  test(
      'rejoins agreeing clocks after rejected noisy anchors without a false seam',
      () {
    final mapping = fitSubtitleClock([
      anchor(10000, 0, 1),
      anchor(20000, 0, 2),
      anchor(30000, 0, 3),
      anchor(40000, 5000, 4),
      anchor(50000, 3000, 5),
      anchor(60000, 1000, 6),
      for (var i = 7; i <= 20; i++) anchor(i * 10000, 0, i),
    ])!;
    expect(mapping.regionCount, 1);
    expect(mapping.mapCue(44000, 46000), (44000, 46000));
    expect(mapping.rejectedCueCount, 2);
  });

  test('does not emit negative corrected times', () {
    final mapping = fitSubtitleClock([
      anchor(10000, -9000, 1),
      anchor(20000, -9000, 2),
      anchor(30000, -9000, 3),
      anchor(40000, -9000, 4),
    ])!;
    expect(mapping.mapCue(8000, 10000), isNull);
    expect(mapping.mapCue(9000, 10000), (0, 1000));
  });
}
