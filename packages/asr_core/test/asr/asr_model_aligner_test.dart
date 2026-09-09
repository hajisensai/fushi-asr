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
      ).align(_speech(session), transcript))!;
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
      ).align(_speech(session), _text(<String>['ab'])))!;
      expect(result.tokens, <String>['ab']);
      expect(result.tokenOffsetsMs, <int>[20]);
      expect(result.tokenEndOffsetsMs, <int>[120]);
    },
  );

  test(
    'a vocabulary gap skips that character instead of killing the segment',
    () async {
      // 调轴词表与一遍模型的词表是两张表；缺字是常态，不是致命错误。缺掉的字
      // 与标点同路，时间由相邻锚点继承，整段照常对齐。
      final _Session session = _Session(<int>[0, 1, 1, 0]);
      final AsrDecodedSegment result = (await _aligner(
        session,
      ).align(_speech(session), _text(<String>['ax'])))!;
      expect(result.tokens, <String>['ax']);
      expect(result.tokenOffsetsMs, <int>[20]);
      expect(result.tokenEndOffsetsMs, <int>[60]);
      expect(session.calls, 1);
    },
  );

  test(
    'a mostly out-of-vocabulary body is unmeasurable, not a failure',
    () async {
      // 能进声学路径的字不到一半：剩下的锚点撑不住整段时间分配，判无从度量。
      final _Session session = _Session(<int>[0, 1, 0]);
      expect(
        await _aligner(session).align(_speech(session), _text(<String>['axx'])),
        isNull,
      );
      expect(session.calls, 0);
    },
  );

  test('punctuation-only body carries no acoustic evidence', () async {
    final _Session session = _Session(<int>[0, 1, 0]);
    expect(
      await _aligner(session).align(_speech(session), _text(<String>['… '])),
      isNull,
    );
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
      ).align(_speech(session), AsrDecodedSegment.empty))!;
      expect(result.isEmpty, isTrue);
      expect(session.calls, 0);
    },
  );

  test('impossible repeated-character CTC path is unalignable', () async {
    final _Session session = _Session(<int>[1, 1]);
    expect(
      await _aligner(session).align(_speech(session), _text(<String>['aa'])),
      isNull,
    );
    expect(session.calls, 1);
  });

  test(
    'blank-only and uniform model output are not accepted as evidence',
    () async {
      for (final bool uniform in <bool>[false, true]) {
        final _Session session = _Session(<int>[0, 0, 0, 0], uniform: uniform);
        expect(
          await _aligner(session).align(_speech(session), _text(<String>['a'])),
          isNull,
        );
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
