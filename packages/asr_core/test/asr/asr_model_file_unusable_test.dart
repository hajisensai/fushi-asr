/// 模型文件坏档的分类与自愈。
///
/// 背景：用户点转录，弹层里只有一句
/// `PlatformException(ORT_ERROR, Load model from ...encoder-epoch-99-avg-1.onnx
/// failed:Protobuf parsing failed., false, null)`。那个文件存在、非空，所以
/// [isAsrModelFileReady] 判它已就绪、下载器把它当就绪跳过，同一个错误每次转录
/// 复现，用户除了手删整个模型目录没有出路。
///
/// 这里钉两件事：哪些失败**才**算文件坏了（误判会删掉能跑的模型），以及坏档被
/// 判定后确实从磁盘上消失、异常带着够用的诊断信息。
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_asr_core/src/asr/asr_engine.dart';
import 'package:fushi_asr_core/src/asr/asr_model_manifest.dart';
import 'package:fushi_asr_core/src/asr/asr_model_store.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';

class _FakeSession implements OnnxSession {
  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async =>
      const <String, OnnxTensor>{};

  @override
  Future<void> close() async {}
}

/// 让指定文件名的建会话失败，错误对象可控。
class _FailingFactory implements OnnxSessionFactory {
  _FailingFactory({required this.failFileName, required this.error});

  final String failFileName;
  final Object error;

  @override
  Future<Set<OnnxExecutionProvider>> availableAcceleratedProviders() async =>
      const <OnnxExecutionProvider>{};

  @override
  Future<int?> deviceMemoryBudgetBytes() async => null;

  @override
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    void Function(OnnxProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    if (modelPath.endsWith(failFileName)) {
      throw error;
    }
    onProviderResolved?.call(
      OnnxProviderResolution(
        requested: providers,
        effective: providers.first,
      ),
    );
    return _FakeSession();
  }
}

/// 用户截图里那句的原文形态：插件后端把 ORT 的错误包进 PlatformException，
/// `toString()` 出来就是这一串。
const String kPluginProtobufFailure =
    'PlatformException(ORT_ERROR, Load model from '
    r'D:\hibiki\support\asr_models\reazonspeech-k2-v2\'
    'encoder-epoch-99-avg-1.onnx failed:Protobuf parsing failed., false, null)';

void main() {
  group('isOnnxUnreadableModelFailure', () {
    test('用户报障的那句 PlatformException 原文认得出来', () {
      expect(isOnnxUnreadableModelFailure(kPluginProtobufFailure), isTrue);
      expect(
        isOnnxUnreadableModelFailure(Exception(kPluginProtobufFailure)),
        isTrue,
      );
    });

    test('ORT 三种「文件读不出图」的实测原文都认得出来', () {
      // onnxruntime 1.22 本机实测：截断档 / 空档 / 文件不存在。
      expect(
        isOnnxUnreadableModelFailure(
          '[ONNXRuntimeError] : 7 : INVALID_PROTOBUF : Load model from '
          'trunc.onnx failed:Protobuf parsing failed.',
        ),
        isTrue,
      );
      expect(
        isOnnxUnreadableModelFailure(
          '[ONNXRuntimeError] : 1 : FAIL : Load model from zero.onnx failed:'
          'onnxruntime/core/graph/model.cc:166 onnxruntime::Model::Model '
          'ModelProto does not have a graph.',
        ),
        isTrue,
      );
      expect(
        isOnnxUnreadableModelFailure(
          '[ONNXRuntimeError] : 3 : NO_SUCHFILE : Load model from gone.onnx '
          "failed:Load model gone.onnx failed. File doesn't exist",
        ),
        isTrue,
      );
    });

    test('EP / 显存 / 运行时类失败不算坏档——误判会删掉能跑的模型', () {
      expect(
        isOnnxUnreadableModelFailure(
          Exception('directml rejected: MLOperatorAuthorImpl.cpp(2851) '
              'E_INVALIDARG'),
        ),
        isFalse,
      );
      expect(
        isOnnxUnreadableModelFailure(
          '[ONNXRuntimeError] : 2 : INVALID_ARGUMENT : Failed to allocate '
          'memory for requested buffer of size 4294967296',
        ),
        isFalse,
      );
      expect(isOnnxUnreadableModelFailure(StateError('boom')), isFalse);
    });
  });

  group('AsrEngineLoader.load 遇到坏档', () {
    late Directory tempDir;
    late AsrModelStore store;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('asr_unusable_');
      store = AsrModelStore(tempDir, kAsrJapanesePack);
      for (final AsrModelFile f in kAsrJapanesePack.files) {
        final File file = store.fileFor(f.role);
        if (f.role == AsrModelRole.tokens) {
          file.writeAsStringSync(
            '<blk>\t0\nあ\t1\nい\t2\n<unk>\t3\n<sos/eos>\t4\n',
          );
        } else {
          file.writeAsBytesSync(<int>[1]);
        }
      }
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<Object?> load(OnnxSessionFactory factory) async {
      try {
        await AsrEngineLoader(factory: factory).load(
          store: store,
          variant: AsrEncoderVariant.fp32,
          preference: AsrAccelerationPreference.cpuOnly,
          useGreedyGraph: false,
          useStaticEncoderBuckets: false,
          useFp16Encoder: false,
        );
        return null;
      } catch (error) {
        return error;
      }
    }

    test('编码器读不出图：删档 + 抛带诊断的异常，下次下载能重新取回', () async {
      final File encoder = store.fileFor(AsrModelRole.encoderFp32);
      final Object? error = await load(
        _FailingFactory(
          failFileName: 'encoder-epoch-99-avg-1.onnx',
          error: kPluginProtobufFailure,
        ),
      );

      expect(error, isA<AsrModelFileUnusableException>());
      final AsrModelFileUnusableException e =
          error! as AsrModelFileUnusableException;
      expect(e.fileName, 'encoder-epoch-99-avg-1.onnx');
      expect(e.path, encoder.path);
      expect(e.actualBytes, 1);
      expect(
        e.expectedBytes,
        kAsrJapanesePack.fileForRole(AsrModelRole.encoderFp32).expectedBytes,
      );
      expect(e.deleted, isTrue);
      expect(e.cause, kPluginProtobufFailure);
      expect(
        encoder.existsSync(),
        isFalse,
        reason: '坏档必须从磁盘消失，否则宽松的就绪判定会让它继续被跳过',
      );
    });

    test('decoder 坏档只删 decoder，不牵连同目录其它文件', () async {
      final Object? error = await load(
        _FailingFactory(
          failFileName: 'decoder-epoch-99-avg-1.onnx',
          error: '[ONNXRuntimeError] : 7 : INVALID_PROTOBUF : Load model from '
              'decoder-epoch-99-avg-1.onnx failed:Protobuf parsing failed.',
        ),
      );

      expect(error, isA<AsrModelFileUnusableException>());
      expect(
        (error! as AsrModelFileUnusableException).fileName,
        'decoder-epoch-99-avg-1.onnx',
      );
      expect(store.fileFor(AsrModelRole.decoderFp32).existsSync(), isFalse);
      expect(store.fileFor(AsrModelRole.encoderFp32).existsSync(), isTrue);
      expect(store.fileFor(AsrModelRole.joinerFp32).existsSync(), isTrue);
      expect(store.fileFor(AsrModelRole.vad).existsSync(), isTrue);
      expect(store.fileFor(AsrModelRole.tokens).existsSync(), isTrue);
    });

    test('非坏档失败原样抛出，一个文件都不删', () async {
      final Object failure = StateError('cuda out of memory');
      final Object? error = await load(
        _FailingFactory(
          failFileName: 'encoder-epoch-99-avg-1.onnx',
          error: failure,
        ),
      );

      expect(error, same(failure));
      for (final AsrModelFile f in kAsrJapanesePack.files) {
        expect(
          store.fileFor(f.role).existsSync(),
          isTrue,
          reason: f.fileName,
        );
      }
    });
  });
}
