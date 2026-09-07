import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_asr_core/src/asr/asr_cue_builder.dart';
import 'package:fushi_asr_core/src/asr/asr_transcribe_job.dart';
import 'package:fushi_asr_core/src/asr/asr_transcription_service.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:path/path.dart' as p;

AsrTranscribedSegment _seg({
  required int startMs,
  required int endMs,
  required String text,
  required List<int> times,
}) =>
    AsrTranscribedSegment(
      audioFileIndex: 0,
      startMs: startMs,
      endMs: endMs,
      tokens: text.split(''),
      tokenTimesMs: times,
    );

void main() {
  group('AsrCue 带逐 token 时间', () {
    test('切句后每条 cue 的 token 与相对起点的偏移', () {
      const AsrCueBuilder builder = AsrCueBuilder();
      final List<AsrCue> cues = builder.build(<AsrTranscribedSegment>[
        _seg(
          startMs: 1000,
          endMs: 5000,
          text: 'ああ。いい',
          times: <int>[1200, 1300, 1400, 3000, 3100],
        ),
      ]);
      expect(cues, hasLength(2));
      expect(cues[0].tokens, <String>['あ', 'あ', '。']);
      // 段首 cue 起点 = VAD 段起点 1000。
      expect(cues[0].tokenOffsetsMs, <int>[200, 300, 400]);
      // 第二句起点 = 首 token 3000 − leadIn 150。
      expect(cues[1].startMs, 2850);
      expect(cues[1].tokens, <String>['い', 'い']);
      expect(cues[1].tokenOffsetsMs, <int>[150, 250]);
    });
  });

  group('sidecar 序列化 / 解析', () {
    test('与 SRT 同序、跳过空文本 cue，往返等价', () {
      final List<AsrCue> cues = <AsrCue>[
        const AsrCue(startMs: 0, endMs: 500, text: '', audioFileIndex: 0),
        const AsrCue(
          startMs: 600,
          endMs: 900,
          text: 'あ い',
          audioFileIndex: 0,
          tokens: <String>['あ', ' い'],
          tokenOffsetsMs: <int>[-20, 100],
        ),
      ];
      final String text = serializeAsrCueTokens(cues);
      expect(text.split('\n').where((String l) => l.isNotEmpty), hasLength(1));
      final List<({List<String> tokens, List<int> offsetsMs})>? rows =
          parseAsrCueTokens(text);
      expect(rows, hasLength(1));
      expect(rows!.single.tokens, <String>['あ', ' い']);
      expect(rows.single.offsetsMs, <int>[-20, 100]);
    });

    test('坏行整体判无效', () {
      expect(parseAsrCueTokens('{"t":["a"],"o":[1]}\n{"t":["a"],"o"'), isNull);
      expect(parseAsrCueTokens('{"t":["a","b"],"o":[1]}\n'), isNull);
      expect(parseAsrCueTokens(''), isEmpty);
    });
  });

  group('attachCueTokenTiming', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('asr_cue_tokens_');
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    int jobSeq = 0;
    File job({required bool state, String? sidecar}) {
      final Directory dir = Directory(p.join(tmp.path, 'job${jobSeq++}'))
        ..createSync();
      final File srt = File(p.join(dir.path, AsrJobFiles.srt))
        ..writeAsStringSync('');
      if (state) {
        File(p.join(dir.path, AsrJobFiles.state)).writeAsStringSync('{}');
      }
      if (sidecar != null) {
        File(p.join(dir.path, AsrJobFiles.cueTokens))
            .writeAsStringSync(sidecar);
      }
      return srt;
    }

    test('行数与 cue 数相同 → 逐条读出', () async {
      final File srt = job(
        state: true,
        sidecar: '{"t":["a"],"o":[10]}\n{"t":["b","c"],"o":[0,50]}\n',
      );
      final List<AsrCueTokenTiming>? rows =
          await AsrTranscriptionService.readCueTokenTimings(
        srt.path,
        expectedCount: 2,
      );
      expect(rows, isNotNull);
      expect(rows![0].tokens, <String>['a']);
      expect(rows[1].offsetsMs, <int>[0, 50]);
    });

    test('行数不符 / sidecar 缺失 / 不是转录产物 → 一条都不给', () async {
      // 行号错位比没有更糟，所以三种失态一律整体返回 null。
      expect(
        await AsrTranscriptionService.readCueTokenTimings(
          job(state: true, sidecar: '{"t":["a"],"o":[10]}\n').path,
          expectedCount: 2,
        ),
        isNull,
      );
      expect(
        await AsrTranscriptionService.readCueTokenTimings(
          job(state: true).path,
          expectedCount: 2,
        ),
        isNull,
      );
      expect(
        await AsrTranscriptionService.readCueTokenTimings(
          job(state: false, sidecar: '{"t":["a"],"o":[10]}\n' * 2).path,
          expectedCount: 2,
        ),
        isNull,
      );
    });
  });
}
