import 'dart:io';

import 'package:fushi_asr_core/src/asr/asr_model_manifest.dart';
import 'package:fushi_asr_core/src/asr/asr_model_store.dart';
import 'package:fushi_asr_core/src/asr/asr_transcribe_isolate.dart';
import 'package:fushi_asr_core/src/asr/asr_transcription_service.dart';
import 'package:fushi_asr_core/src/onnx/model_file_downloader.dart';
import 'package:fushi_asr_core/src/onnx/onnx_inference.dart';
import 'package:test/test.dart';

OnnxSessionFactory _unusedFactory() =>
    throw StateError('Download tests must not create model sessions');

class _Store extends AsrModelStore {
  _Store(AsrModelPack pack, this.label, {this.fail = false})
      : super(Directory('unused-$label'), pack);

  final String label;
  final bool fail;
  final List<AsrEncoderVariant> variants = <AsrEncoderVariant>[];

  @override
  Stream<ModelDownloadEvent> download(
    AsrEncoderVariant variant, {
    ModelFileDownloader? downloader,
  }) async* {
    variants.add(variant);
    yield ModelDownloadEvent(
      fileName: label,
      receivedBytes: 50,
      totalBytes: 100,
    );
    if (fail) throw StateError('Second model download failed');
    yield ModelDownloadEvent(
      fileName: label,
      receivedBytes: 100,
      totalBytes: 100,
    );
    yield ModelDownloadEvent(
      fileName: label,
      receivedBytes: 100,
      totalBytes: 100,
      done: true,
    );
  }
}

AsrTranscriptionService _service(
  _Store first,
  Future<AsrModelStore> Function() alignment,
) =>
    AsrTranscriptionService(
      backend: const AsrIsolateBackend(buildFactory: _unusedFactory),
      openStore: (AsrLanguage language) async => first,
      openAlignmentStore: alignment,
      alignGeneratedSubtitles: true,
    );

void main() {
  test('two model downloads publish exactly one final completion event',
      () async {
    final _Store first = _Store(asrModelPackFor(AsrLanguage.japanese), 'asr');
    final _Store second = _Store(kAsrOmnilingualPack, 'aligner');
    final List<ModelDownloadEvent> events =
        await _service(first, () async => second)
            .downloadModel(
                language: AsrLanguage.japanese, variant: AsrEncoderVariant.fp32)
            .toList();
    expect(first.variants, <AsrEncoderVariant>[AsrEncoderVariant.fp32]);
    expect(second.variants, <AsrEncoderVariant>[AsrEncoderVariant.int8]);
    expect(events.map((ModelDownloadEvent event) => event.fileName),
        <String>['asr', 'asr', 'aligner', 'aligner', 'aligner']);
    expect(events.where((ModelDownloadEvent event) => event.done),
        <ModelDownloadEvent>[events.last]);
    expect(events.last.fileName, 'aligner');
    expect(events.last.receivedBytes, events.last.totalBytes);
  });

  for (final AsrEncoderVariant variant in AsrEncoderVariant.values) {
    test(
        'CTC first pass $variant reuses its model without opening a second store',
        () async {
      final _Store first = _Store(kAsrOmnilingualPack, 'ctc');
      final List<ModelDownloadEvent> events = await _service(first, () async {
        fail(
            'A CTC first-pass model must not download another alignment model');
      }).downloadModel(language: AsrLanguage.german, variant: variant).toList();
      expect(first.variants, <AsrEncoderVariant>[variant]);
      expect(events, hasLength(3));
      expect(events.where((ModelDownloadEvent event) => event.done),
          <ModelDownloadEvent>[events.last]);
    });
  }

  test('failure downloading the aligner never emits a premature done event',
      () async {
    final _Store first = _Store(asrModelPackFor(AsrLanguage.japanese), 'asr');
    final _Store second = _Store(kAsrOmnilingualPack, 'aligner', fail: true);
    final List<ModelDownloadEvent> received = <ModelDownloadEvent>[];
    await expectLater(
      _service(first, () async => second)
          .downloadModel(
              language: AsrLanguage.japanese, variant: AsrEncoderVariant.int8)
          .forEach(received.add),
      throwsStateError,
    );
    expect(received.map((ModelDownloadEvent event) => event.fileName),
        <String>['asr', 'asr', 'aligner']);
    expect(received.any((ModelDownloadEvent event) => event.done), isFalse);
  });
}
