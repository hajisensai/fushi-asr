import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_cue_builder.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:test/test.dart';

void main() {
  test('aligned intervals survive decoded conversion and JSON checkpoint', () {
    final segment = AsrTranscribedSegment.fromDecoded(
      audioFileIndex: 1,
      speech: AsrSpeechSegment(
        startSample: 16000,
        samples: Float32List(32000),
      ),
      decoded: AsrDecodedSegment(
        tokens: ['你好', '。'],
        tokenOffsetsMs: [240, 680],
        tokenEndOffsetsMs: [680, 680],
      ),
    );
    final restored = AsrTranscribedSegment.fromJson(
      jsonDecode(jsonEncode(segment.toJson())) as Map<String, Object?>,
    );
    expect(restored.tokenTimesMs, [1240, 1680]);
    expect(restored.tokenEndTimesMs, [1680, 1680]);
    expect(restored.toJson(), segment.toJson());
    expect(restored.text, '你好。');
    expect(() => restored.tokenEndTimesMs!.add(1), throwsUnsupportedError);
  });

  test('old checkpoints retain VAD timing without alignment metadata', () {
    final segment = AsrTranscribedSegment.fromJson({
      'f': 0,
      's': 0,
      'e': 2000,
      't': ['你好'],
      'm': [400],
    });
    expect(segment.tokenEndTimesMs, isNull);
    expect(segment.toJson().containsKey('me'), isFalse);
    final cue = const AsrCueBuilder().build([segment]).single;
    expect(cue.startMs, 0);
    expect(cue.endMs, 2000);
  });

  test('aligned short sentences preserve silence and sidecar absolute times',
      () {
    final segment = AsrTranscribedSegment(
      audioFileIndex: 1,
      startMs: 1000,
      endMs: 5000,
      tokens: ['「', '好', '。', '」', '走', '！'],
      tokenTimesMs: [1240, 1240, 1400, 1400, 3200, 3360],
      tokenEndTimesMs: [1240, 1400, 1400, 1400, 3360, 3360],
    );
    final cues = const AsrCueBuilder(leadInMs: 900, minCueMs: 1000)
        .build([segment], fileOffsetsMs: [0, 10000]);
    expect(cues.map((c) => c.text), ['「好。」', '走！']);
    expect(cues.map((c) => c.startMs), [11240, 13200]);
    expect(cues.map((c) => c.endMs), [11400, 13360]);
    final sidecar = parseAsrCueTokens(serializeAsrCueTokens(cues))!;
    expect(sidecar.length, cues.length);
    for (var i = 0; i < cues.length; i++) {
      expect(sidecar[i].tokens, cues[i].tokens);
      expect(sidecar[i].offsetsMs, cues[i].tokenOffsetsMs);
    }
    expect(sidecar[0].offsetsMs.map((t) => t + cues[0].startMs),
        [11240, 11240, 11400, 11400]);
    expect(
        serializeAsrCuesToSrt(cues), contains('00:00:11,240 --> 00:00:11,400'));
  });

  test('silence splitting measures previous token end, not its duration', () {
    final segment = AsrTranscribedSegment(
      audioFileIndex: 0,
      startMs: 0,
      endMs: 6000,
      tokens: ['长音', '连读', '停顿后'],
      tokenTimesMs: [100, 2100, 4000],
      tokenEndTimesMs: [2000, 2300, 4500],
    );
    final cues = const AsrCueBuilder().build([segment]);
    expect(cues.map((c) => c.text), ['长音连读', '停顿后']);
    expect(cues.map((c) => c.endMs), [2300, 4500]);
  });

  test('invalid aligned intervals fail instead of writing invalid SRT', () {
    for (final ends in [
      [50],
      [2100]
    ]) {
      final segment = AsrTranscribedSegment(
        audioFileIndex: 0,
        startMs: 0,
        endMs: 2000,
        tokens: ['字'],
        tokenTimesMs: [100],
        tokenEndTimesMs: ends,
      );
      expect(() => const AsrCueBuilder().build([segment]), throwsStateError);
    }
  });
}
