@TestOn('vm')
library;

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:fushi_asr_onnx_ffi/src/ort_provisioning.dart';
import 'package:fushi_asr_onnx_ffi/src/ort_runtime.dart';

Uint8List _zip(Map<String, List<int>> entries) {
  final Archive archive = Archive();
  entries.forEach((String name, List<int> bytes) {
    archive.add(ArchiveFile.bytes(name, Uint8List.fromList(bytes)));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  group('候选序列', () {
    // 这条顺序是 System32 那份旧 ORT 的直接教训：托管副本必须排在裸库名前面，
    // 否则每次启动都先撞上系统目录里的旧版。
    test('托管副本排在裸库名之前、显式指定之后', () {
      final List<String> candidates = OrtRuntime.resolveLibraryCandidates(
        environment: <String, String>{'ASR_ONNXRUNTIME_LIB': 'X:/explicit.dll'},
        executablePath: r'C:\app\dart.exe',
        managedDir: r'D:\data\asr_runtime\onnxruntime-1.22.0-win-x64',
      );
      expect(candidates.first, 'X:/explicit.dll');
      final int managed = candidates.indexWhere((String c) => c.contains('asr_runtime'));
      final int bare = candidates.indexOf(OrtRuntime.defaultLibraryFileName());
      expect(managed, greaterThan(0), reason: '托管副本必须在候选里');
      expect(bare, greaterThan(managed), reason: '裸库名会先撞上系统目录的旧 ORT');
    });

    test('没有托管副本时候选序列与原来一致', () {
      final List<String> candidates = OrtRuntime.resolveLibraryCandidates(
        environment: const <String, String>{},
        executablePath: r'C:\app\dart.exe',
        managedDir: '',
      );
      expect(candidates, hasLength(2));
    });
  });

  group('包校验', () {
    test('长度不符即报错，不做摘要', () {
      expect(
        () => verifyOrtPackage(Uint8List.fromList(<int>[1, 2, 3]),
            expectedBytes: 4, expectedSha256: 'whatever'),
        throwsA(isA<OrtProvisionCorrupt>()),
      );
    });

    // 长度对得上、内容被换掉——这正是只校验长度会放过去的那类坏包。
    test('长度相同但内容不同必须被摘要挡下', () {
      final Uint8List good = Uint8List.fromList(utf8.encode('good-package'));
      final Uint8List evil = Uint8List.fromList(utf8.encode('evil-package'));
      expect(good.length, evil.length);
      final String digest = sha256.convert(good).toString();
      expect(
        () => verifyOrtPackage(evil,
            expectedBytes: good.length, expectedSha256: digest),
        throwsA(isA<OrtProvisionCorrupt>()),
      );
      expect(
        () => verifyOrtPackage(good,
            expectedBytes: good.length, expectedSha256: digest),
        returnsNormally,
      );
    });
  });

  group('解压', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ort_prov_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('按 rid 取出本架构的 DLL，平铺落地', () {
      final Uint8List pkg = _zip(<String, List<int>>{
        'runtimes/win-x64/native/onnxruntime.dll': utf8.encode('x64-runtime'),
        'runtimes/win-x64/native/onnxruntime_providers_shared.dll':
            utf8.encode('x64-shared'),
        'runtimes/win-arm64/native/onnxruntime.dll': utf8.encode('arm64-runtime'),
      });
      extractOrtNative(pkg, rid: 'win-x64', target: dir);
      expect(File(p.join(dir.path, 'onnxruntime.dll')).readAsStringSync(),
          'x64-runtime');
      expect(
          File(p.join(dir.path, 'onnxruntime_providers_shared.dll'))
              .readAsStringSync(),
          'x64-shared');
    });

    // providers_shared 缺席时 DML/CUDA 会静默退回 CPU——「解压成功但没加速」
    // 是这里最坏的失败形态，必须当场报错而不是留给用户去猜为什么慢。
    test('缺 providers_shared 就报错，不许半装', () {
      final Uint8List pkg = _zip(<String, List<int>>{
        'runtimes/win-x64/native/onnxruntime.dll': utf8.encode('x64-runtime'),
      });
      expect(() => extractOrtNative(pkg, rid: 'win-x64', target: dir),
          throwsA(isA<OrtProvisionCorrupt>()));
    });

    test('架构不匹配时报错而不是落一份别的架构', () {
      final Uint8List pkg = _zip(<String, List<int>>{
        'runtimes/win-arm64/native/onnxruntime.dll': utf8.encode('arm64'),
        'runtimes/win-arm64/native/onnxruntime_providers_shared.dll':
            utf8.encode('arm64-shared'),
      });
      expect(() => extractOrtNative(pkg, rid: 'win-x64', target: dir),
          throwsA(isA<OrtProvisionCorrupt>()));
      expect(File(p.join(dir.path, 'onnxruntime.dll')).existsSync(), isFalse);
    });
  });

  group('下载源', () {
    test('rid 映射覆盖三种 Windows 架构', () {
      expect(ortRuntimeIdentifier(Abi.windowsX64), 'win-x64');
      expect(ortRuntimeIdentifier(Abi.windowsArm64), 'win-arm64');
      expect(ortRuntimeIdentifier(Abi.windowsIA32), 'win-x86');
      expect(() => ortRuntimeIdentifier(Abi.linuxX64),
          throwsA(isA<OrtProvisionUnsupported>()));
    });

    // 下的必须是 DirectML 那份：GitHub release 的 onnxruntime-win-x64 是纯 CPU
    // 构建，装上去能转录但 GPU 加速会静默消失。
    test('直链指向 NuGet 的 DirectML 包与钉死的版本', () {
      final Uri url = Uri.parse(ortPackageUrl());
      expect(url.host, 'api.nuget.org');
      expect(url.path, contains('microsoft.ml.onnxruntime.directml'));
      expect(url.path, endsWith('.$kOrtPackageVersion.nupkg'));
    });

    // 装的版本低于绑定要求 = 装了也用不了（GetApi 返回 nullptr）。
    test('钉的版本满足绑定所需的 API 版本', () {
      final int major = int.parse(kOrtPackageVersion.split('.')[0]);
      final int minor = int.parse(kOrtPackageVersion.split('.')[1]);
      expect(major, 1);
      expect(minor, greaterThanOrEqualTo(kOrtApiVersion));
    });
  });
}
