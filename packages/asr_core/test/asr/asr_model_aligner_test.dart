import 'dart:typed_data';

import 'package:fushi_asr_core/src/asr/asr_ctc_decoder.dart';
import 'package:fushi_asr_core/src/asr/asr_model_aligner.dart';
import 'package:fushi_asr_core/src/asr/asr_types.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';
import 'package:test/test.dart';

class _Session implements OnnxSession {
  _Session(this.plan, {this.uniform = false});
  final List<int> plan;
  final bool uniform;
  int calls = 0;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    calls++;
    expect(inputs[AsrModelIo.ctcInputX]!.shape, <int>[1, plan.length * 320]);
    final Float32List data = Float32List(plan.length * 3);
    for (int t = 0; t < plan.length; t++) {
      for (int v = 0; v < 3; v++) {
        data[t * 3 + v] = uniform ? 0 : (v == plan[t] ? 8 : -8);
      }
    }
    return <String, OnnxTensor>{
      AsrModelIo.ctcOutputLogits: OnnxTensor.float32(data, <int>[
        1,
        plan.length,
        3,
      ]),
    };
  }

  @override
  Future<void> close() async {}
}

AsrModelAligner _aligner(_Session session, {String? vocabulary}) {
  final AsrTokenTable tokens = AsrTokenTable.parse(
    vocabulary ?? '<s> 0\na 1\nb 2\n',
    blankToken: '<s>',
  );
  return AsrModelAligner(
    decoder: AsrCtcDecoder(model: session, tokens: tokens),
    tokens: tokens,
  );
}

AsrSpeechSegment _speech(_Session session) => AsrSpeechSegment(
  startSample: 16000,
  samples: Float32List(session.plan.length * 320),
);

AsrDecodedSegment _text(List<String> tokens) => AsrDecodedSegment(
  tokens: tokens,
  tokenOffsetsMs: List<int>.filled(tokens.length, 99999),
);

void main() {
  test(
    'second model run calibrates start/end while preserving original tokens',
    () async {
      final _Session session = _Session(<int>[0, 1, 1, 0, 2, 2, 0]);
      final AsrDecodedSegment transcript = _text(<String>[
        '「',
        'A',
        '、 ',
        'b',
        '！」',
      ]);
      final AsrDecodedSegment result = (await _aligner(
        session,
      ).align(_speech(session), transcript)).segment!;
      expect(session.calls, 1);
      expect(result.tokens, transcript.tokens);
      expect(result.text, '「A、 b！」');
      expect(result.tokenOffsetsMs, <int>[20, 20, 60, 80, 120]);
      expect(result.tokenEndOffsetsMs, <int>[20, 60, 60, 120, 120]);
      expect(transcript.tokenOffsetsMs, everyElement(99999));
    },
  );

  test(
    'BPE transcript token retains its full text and spans all aligned characters',
    () async {
      final _Session session = _Session(<int>[0, 1, 1, 0, 2, 2, 0]);
      final AsrDecodedSegment result = (await _aligner(
        session,
      ).align(_speech(session), _text(<String>['ab']))).segment!;
      expect(result.tokens, <String>['ab']);
      expect(result.tokenOffsetsMs, <int>[20]);
      expect(result.tokenEndOffsetsMs, <int>[120]);
    },
  );

  test('token 尾部缺字：终点推定到后一个锚点，不许拿已知字的终点切掉字音', () async {
    // 缺字**发声**，不像标点。'x' 查不到 token，但它的音在 'a' 之后仍要被这条
    // cue 盖住：终点取后一个声学锚点，没有后锚点就取整段长度（80 ms）。
    // 若退回「与标点同路」，终点会是 'a' 的 60 ms，字幕提前消失。
    final _Session session = _Session(<int>[0, 1, 1, 0]);
    final AsrSegmentAlignment aligned = await _aligner(
      session,
    ).align(_speech(session), _text(<String>['ax']));
    expect(aligned.isRejected, isFalse);
    expect(aligned.segment!.tokens, <String>['ax']);
    expect(aligned.segment!.tokenOffsetsMs, <int>[20]);
    expect(aligned.segment!.tokenEndOffsetsMs, <int>[80]);
    // 终点是推定的，不是声学定位：不能冒充完整对齐成功。
    expect(aligned.estimatedBoundaries, 1);
    expect(session.calls, 1);
  });

  test('token 首部缺字：起点推定到前一个锚点，不许晚出', () async {
    final _Session session = _Session(<int>[0, 1, 1, 0]);
    final AsrSegmentAlignment aligned = await _aligner(
      session,
    ).align(_speech(session), _text(<String>['xa']));
    // 'x' 在 'a' 之前发声，段内没有更早的锚点 -> 取段起点 0，而不是 'a' 的 20。
    expect(aligned.segment!.tokenOffsetsMs, <int>[0]);
    expect(aligned.segment!.tokenEndOffsetsMs, <int>[60]);
    expect(aligned.estimatedBoundaries, 1);
  });

  test('token 内部缺字本来就被两端锚点夹住，不算推定', () async {
    final _Session session = _Session(<int>[0, 1, 1, 0, 2, 2, 0]);
    final AsrSegmentAlignment aligned = await _aligner(
      session,
    ).align(_speech(session), _text(<String>['axb']));
    expect(aligned.segment!.tokenOffsetsMs, <int>[20]);
    expect(aligned.segment!.tokenEndOffsetsMs, <int>[120]);
    expect(aligned.estimatedBoundaries, 0);
  });

  test('整个 token 都缺字：两端都推定成相邻锚点，不是零时长继承', () async {
    final _Session session = _Session(<int>[0, 1, 1, 0]);
    final AsrSegmentAlignment aligned = await _aligner(
      session,
    ).align(_speech(session), _text(<String>['x', 'a']));
    // 'x' 整个查不到：起点没有前锚点取 0，终点取后一个声学锚点 20。
    // 退化成标点式零时长继承的话这里会是 [0, 0]。
    expect(aligned.segment!.tokenOffsetsMs, <int>[0, 20]);
    expect(aligned.segment!.tokenEndOffsetsMs, <int>[20, 60]);
    expect(aligned.estimatedBoundaries, 2);
  });

  test(
    'a mostly out-of-vocabulary body is unmeasurable, not a failure',
    () async {
      // 能进声学路径的字不到一半：剩下的锚点撑不住整段时间分配，判无从度量。
      final _Session session = _Session(<int>[0, 1, 0]);
      final AsrSegmentAlignment aligned = await _aligner(
        session,
      ).align(_speech(session), _text(<String>['axx']));
      expect(
        aligned.rejection,
        AsrAlignmentRejection.tooFewMappableCharacters,
      );
      expect(session.calls, 0);
    },
  );

  test('punctuation-only body carries no acoustic evidence', () async {
    final _Session session = _Session(<int>[0, 1, 0]);
    final AsrSegmentAlignment aligned = await _aligner(
      session,
    ).align(_speech(session), _text(<String>['… ']));
    expect(aligned.rejection, AsrAlignmentRejection.tooFewMappableCharacters);
    expect(session.calls, 0);
  });

  test('missing audio is a wiring error, not an unalignable segment', () async {
    final _Session session = _Session(<int>[0, 1, 0]);
    await expectLater(
      _aligner(session).align(
        AsrSpeechSegment(startSample: 0, samples: Float32List(0)),
        _text(<String>['a']),
      ),
      throwsStateError,
    );
  });

  test(
    'empty transcript creates no invented speech or unnecessary inference',
    () async {
      final _Session session = _Session(<int>[0, 0]);
      final AsrDecodedSegment result = (await _aligner(
        session,
      ).align(_speech(session), AsrDecodedSegment.empty)).segment!;
      expect(result.isEmpty, isTrue);
      expect(session.calls, 0);
    },
  );

  test('impossible repeated-character CTC path is unalignable', () async {
    final _Session session = _Session(<int>[1, 1]);
    final AsrSegmentAlignment aligned = await _aligner(
      session,
    ).align(_speech(session), _text(<String>['aa']));
    expect(aligned.rejection, AsrAlignmentRejection.noViterbiPath);
    expect(session.calls, 1);
  });

  test(
    'blank-only and uniform model output are not accepted as evidence',
    () async {
      for (final bool uniform in <bool>[false, true]) {
        final _Session session = _Session(<int>[0, 0, 0, 0], uniform: uniform);
        final AsrSegmentAlignment aligned = await _aligner(
          session,
        ).align(_speech(session), _text(<String>['a']));
        expect(aligned.rejection, AsrAlignmentRejection.noAcousticEvidence);
      }
    },
  );

  test('SentencePiece alignment vocabulary fails explicitly', () async {
    final _Session session = _Session(<int>[0, 1, 0]);
    await expectLater(
      _aligner(
        session,
        vocabulary: '<s> 0\n▁a 1\nb 2\n',
      ).align(_speech(session), _text(<String>['a'])),
      throwsStateError,
    );
    expect(session.calls, 0);
  });
}
