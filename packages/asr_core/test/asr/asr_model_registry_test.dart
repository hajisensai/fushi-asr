import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr_core/src/asr/asr_model_manifest.dart';
import 'package:fushi_asr_core/src/asr/asr_model_registry.dart';
import 'package:test/test.dart';

/// 一个最小的自带包 JSON：只写 id / languages / files，其余全走缺省。
/// 这是「别人接自己的模型」最常见的形态，缺省值错了这条会先红。
const String _minimalPackJson = '''
{
  "packs": [
    {
      "id": "my-hindi-zipformer",
      "languages": ["hi"],
      "files": [
        {"fileName": "encoder.onnx", "url": "https://example.invalid/e.onnx",
         "expectedBytes": 1, "role": "encoderInt8"},
        {"fileName": "decoder.onnx", "url": "https://example.invalid/d.onnx",
         "expectedBytes": 1, "role": "decoderInt8"},
        {"fileName": "joiner.onnx", "url": "https://example.invalid/j.onnx",
         "expectedBytes": 1, "role": "joinerInt8"},
        {"fileName": "tokens.txt", "url": "https://example.invalid/t.txt",
         "expectedBytes": 1, "role": "tokens"},
        {"fileName": "silero_vad.onnx", "url": "https://example.invalid/v.onnx",
         "expectedBytes": 1, "role": "vad"}
      ]
    }
  ]
}
''';

void main() {
  final AsrModelRegistry builtin = AsrModelRegistry.builtin();

  setUp(() => asrModelRegistry = AsrModelRegistry.builtin());
  tearDown(() => asrModelRegistry = AsrModelRegistry.builtin());

  group('内置注册表', () {
    test('认得 17 种内置语言，且每种恰有一个包', () {
      expect(builtin.languages, hasLength(17));
      for (final AsrLanguage language in AsrLanguage.values) {
        expect(builtin.packForLanguage(language), isNotNull,
            reason: '${language.tag} 没有包');
      }
    });

    test('按 id 能取到包；不认识的 id 返回 null', () {
      expect(builtin.packById(kAsrJapanesePack.id), same(kAsrJapanesePack));
      expect(builtin.packById('nope'), isNull);
    });
  });

  group('JSON 往返', () {
    test('内置每个包 toJson → fromJson 后逐字段相同', () {
      for (final AsrModelPack pack in kAsrModelPacks) {
        final AsrModelPack back = AsrModelPack.fromJson(
          jsonDecode(jsonEncode(pack.toJson())) as Object,
        );
        expect(back.id, pack.id);
        expect(back.displayName, pack.displayName);
        expect(back.sourceUrl, pack.sourceUrl);
        expect(back.architecture, pack.architecture);
        expect(back.indexType, pack.indexType);
        expect(back.decoderContextSize, pack.decoderContextSize);
        expect(back.blankToken, pack.blankToken);
        expect(back.fp32GpuMinBudgetBytes, pack.fp32GpuMinBudgetBytes);
        expect(back.languages.map((AsrLanguage l) => l.tag),
            pack.languages.map((AsrLanguage l) => l.tag));
        expect(back.files.length, pack.files.length);
        for (int i = 0; i < back.files.length; i++) {
          expect(back.files[i].fileName, pack.files[i].fileName);
          expect(back.files[i].url, pack.files[i].url);
          expect(back.files[i].expectedBytes, pack.files[i].expectedBytes);
          expect(back.files[i].role, pack.files[i].role);
          expect(back.files[i].mirrorUrls, pack.files[i].mirrorUrls);
        }
      }
    });

    test('最小自带包：只写 id / languages / files，其余走缺省', () {
      final AsrModelRegistry custom =
          AsrModelRegistry.fromJson(jsonDecode(_minimalPackJson));
      final AsrModelPack pack = custom.packs.single;
      expect(pack.id, 'my-hindi-zipformer');
      expect(pack.architecture, AsrModelArchitecture.transducer);
      expect(pack.indexType, AsrIndexType.int64);
      expect(pack.decoderContextSize, 2);
      expect(pack.blankToken, '<blk>');
      expect(pack.displayName, 'my-hindi-zipformer', reason: '缺省取 id');
      expect(pack.languages.single.tag, 'hi');
      // 缺省 transducer 形态下 filesFor 能凑齐一套 int8 文件。
      expect(pack.filesFor(AsrEncoderVariant.int8), hasLength(5));
    });

    test('CTC 包不写 blankToken → 报错而不是猜', () {
      expect(
        () => AsrModelPack.fromJson(<String, Object?>{
          'id': 'x',
          'architecture': 'ctc',
          'languages': <Object>['xx'],
          'files': <Object>[
            <String, Object?>{
              'fileName': 'm.onnx',
              'url': 'https://example.invalid/m.onnx',
              'expectedBytes': 1,
              'role': 'ctcModelInt8',
            },
          ],
        }),
        throwsA(isA<FormatException>().having(
            (FormatException e) => e.message, 'message', contains('blankToken'))),
      );
    });

    test('字段类型错 → FormatException 带上包 id 和字段名', () {
      expect(
        () => AsrModelPack.fromJson(<String, Object?>{
          'id': 'bad-pack',
          'languages': <Object>['xx'],
          'files': <Object>[
            <String, Object?>{
              'fileName': 'm.onnx',
              'url': 'https://example.invalid/m.onnx',
              'expectedBytes': '不是整数',
              'role': 'encoderInt8',
            },
          ],
        }),
        throwsA(isA<FormatException>()
            .having((FormatException e) => e.message, 'message',
                contains('bad-pack'))
            .having((FormatException e) => e.message, 'message',
                contains('expectedBytes'))),
      );
    });
  });

  group('合并与语言解析', () {
    test('自带包按 id 覆盖内置包，且同语言优先用自带的', () {
      final AsrModelPack override = AsrModelPack.fromJson(<String, Object?>{
        'id': kAsrJapanesePack.id,
        'displayName': '我的日语包',
        'languages': <Object>['ja'],
        'files': <Object>[
          <String, Object?>{
            'fileName': 'e.onnx',
            'url': 'https://example.invalid/e.onnx',
            'expectedBytes': 1,
            'role': 'encoderInt8',
          },
        ],
      });
      final AsrModelRegistry merged =
          builtin.mergedWith(AsrModelRegistry(<AsrModelPack>[override]));
      expect(merged.packs, hasLength(kAsrModelPacks.length),
          reason: '同 id 覆盖，不新增');
      expect(merged.packById(kAsrJapanesePack.id)!.displayName, '我的日语包');
      expect(merged.packForLanguage(AsrLanguage.japanese)!.displayName,
          '我的日语包');
      // 其他语言不受影响。
      expect(merged.packForLanguage(AsrLanguage.english)!.id,
          kAsrEnglishPack.id);
    });

    test('装上自带清单后 AsrLanguage.fromTag 认得新语言', () {
      expect(AsrLanguage.fromTag('hi'), isNull, reason: '内置表里没有印地语');
      asrModelRegistry = builtin.mergedWith(
        AsrModelRegistry.fromJson(jsonDecode(_minimalPackJson)),
      );
      final AsrLanguage? hindi = AsrLanguage.fromTag('hi');
      expect(hindi, isNotNull);
      expect(asrModelPackFor(hindi!).id, 'my-hindi-zipformer');
      // 内置语言照旧。
      expect(AsrLanguage.fromTag('ja'), AsrLanguage.japanese);
      expect(asrModelPackFor(AsrLanguage.japanese).id, kAsrJapanesePack.id);
    });

    test('注册表里没有的语言 → asrModelPackFor 抛出可读错误', () {
      expect(
        () => asrModelPackFor(const AsrLanguage('zz', 'zz')),
        throwsA(isA<StateError>()
            .having((StateError e) => e.message, 'message', contains('zz'))
            .having((StateError e) => e.message, 'message', contains('--models'))),
      );
    });

    test('语言相等只看标签', () {
      expect(const AsrLanguage('ja', '日本語'), const AsrLanguage('ja', '别名'));
      expect(const AsrLanguage('ja', 'x').hashCode,
          const AsrLanguage('ja', 'y').hashCode);
      expect(const AsrLanguage('ja', 'x') == const AsrLanguage('en', 'x'),
          isFalse);
    });
  });

  group('resolve：清单从哪来', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('asr_registry_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('都没给 → 内置表', () async {
      final AsrModelRegistry r = await AsrModelRegistry.resolve(
        dataRoot: tmp,
        environment: const <String, String>{},
      );
      expect(r.packs, hasLength(kAsrModelPacks.length));
    });

    test('数据根下的 models.json 自动生效', () async {
      File('${tmp.path}${Platform.pathSeparator}models.json')
          .writeAsStringSync(_minimalPackJson);
      final AsrModelRegistry r = await AsrModelRegistry.resolve(
        dataRoot: tmp,
        environment: const <String, String>{},
      );
      expect(r.packById('my-hindi-zipformer'), isNotNull);
      expect(r.packs, hasLength(kAsrModelPacks.length + 1));
    });

    test('显式路径不存在 → 报错（探测性来源才静默跳过）', () async {
      await expectLater(
        AsrModelRegistry.resolve(
          explicitPath: '${tmp.path}${Platform.pathSeparator}nope.json',
          dataRoot: tmp,
          environment: const <String, String>{},
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('环境变量指的清单生效', () async {
      final File f = File('${tmp.path}${Platform.pathSeparator}m.json')
        ..writeAsStringSync(_minimalPackJson);
      final AsrModelRegistry r = await AsrModelRegistry.resolve(
        dataRoot: tmp,
        environment: <String, String>{'ASR_MODELS_MANIFEST': f.path},
      );
      expect(r.packById('my-hindi-zipformer'), isNotNull);
    });
  });
}
