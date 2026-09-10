import 'dart:async';
import 'dart:io';

import 'package:fushi_asr/asr.dart';
import 'package:test/test.dart';

String _quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

const _success = '''
printf '%s\\n' 'FUSHI_PROGRESS {"processedMs":0,"totalMs":2000}' >&2
printf '%s\\n' 'FUSHI_PROGRESS {"processedMs":"bad","totalMs":2000}' >&2
printf '%s\\n' 'FUSHI_PROGRESS invalid-json' >&2
printf '%s\\n' 'FUSHI_PROGRESS {"processedMs":2000,"totalMs":2000}' >&2
printf '%s\\n' '{"audio_seconds":2,"segments":[{"start":0.1,"end":1.9,"text":" 日本語 "}]}'
''';

void main() {
  group('Apple native input adapter', () {
    late Directory work;
    late File calls;
    late File conversions;
    late String audio;

    Future<String> script(String name, String source) async {
      final file = File('${work.path}/$name');
      await file.writeAsString('#!/bin/sh\nset -eu\n$source\n');
      final result = await Process.run('/bin/chmod', ['+x', file.path]);
      expect(result.exitCode, 0);
      return file.path;
    }

    Future<AppleTranscribeRunner> runner(String helper,
        {String? converter, bool useCompatibilityPcm = false}) async {
      final executable = await script('native', '''
printf '%s\\n' "\$1" >> ${_quote(calls.path)}
$helper
''');
      final ffmpeg = converter == null
          ? '${work.path}/ffmpeg-must-not-run'
          : await script('ffmpeg', '''
for arg in "\$@"; do destination="\$arg"; done
printf '%s\\n' "\$destination" >> ${_quote(conversions.path)}
$converter
''');
      return AppleTranscribeRunner(
          executablePath: executable,
          ffmpegExecutablePath: ffmpeg,
          useCompatibilityPcm: useCompatibilityPcm);
    }

    Future<TranscribeOutcome> run(AppleTranscribeRunner adapter,
            {TranscribeCancellation? cancellation,
            void Function(TranscribeProgress)? onProgress}) =>
        adapter.run(
            audioPaths: [audio],
            language: AsrLanguage.japanese, audioProfile: AsrAudioProfile.cleanSpeech,
            cancellation: cancellation,
            onProgress: onProgress);

    setUp(() async {
      work = await Directory.systemTemp.createTemp('fushi_apple_adapter_test_');
      calls = File('${work.path}/calls');
      conversions = File('${work.path}/conversions');
      // A space and Japanese filename verify argument handling without a shell.
      audio = '${work.path}/日本語 audio.m4b';
    });
    tearDown(() => work.delete(recursive: true));

    test('passes original file directly without ffmpeg or timestamp changes',
        () async {
      final adapter = await runner(_success);
      final progress = <TranscribeProgress>[];
      final output = await run(adapter, onProgress: progress.add);
      expect(await calls.readAsLines(), [audio]);
      expect(conversions.existsSync(), false);
      expect(output.engine, 'apple-speechtranscriber');
      expect(output.audioMs, 2000);
      expect(output.cues.single.startMs, 100);
      expect(output.cues.single.endMs, 1900);
      expect(output.cues.single.text, '日本語');
      expect(
          progress.map((p) => p.phase), ['load', 'transcribe', 'transcribe']);
      expect(progress.last.processedMs, 2000);
    });

    test('only unsupported AVAudioFile input gets one compatible WAV retry',
        () async {
      final adapter = await runner('''
if [ "\$1" = ${_quote(audio)} ]; then
  printf '%s\\n' 'FUSHI_AUDIO_INPUT_UNSUPPORTED format' >&2
  exit 65
fi
$_success
''', converter: ': > "\$destination"');
      final output = await run(adapter);
      final converted = (await conversions.readAsLines()).single;
      expect(await calls.readAsLines(), [audio, converted]);
      expect(converted.endsWith('/audio.wav'), true);
      expect(File(converted).existsSync(), false);
      expect(output.cues.single.text, '日本語');
    });

    test('explicit compatibility mode reproduces old preprocessing directly',
        () async {
      final adapter = await runner(_success,
          useCompatibilityPcm: true, converter: ': > "\$destination"');
      final output = await run(adapter);
      final converted = (await conversions.readAsLines()).single;
      expect(adapter.useCompatibilityPcm, true);
      expect(await calls.readAsLines(), [converted]);
      expect(File(converted).existsSync(), false);
      expect(output.cues.single.text, '日本語');
    });

    for (final scenario in [
      (name: 'model error', code: 1, message: 'model unavailable'),
      (
        name: 'tag without input exit code',
        code: 1,
        message: 'FUSHI_AUDIO_INPUT_UNSUPPORTED unexpected'
      ),
      (
        name: 'exit code without input tag',
        code: 65,
        message: 'internal error'
      ),
    ]) {
      test('${scenario.name} does not trigger conversion or a model retry',
          () async {
        final adapter = await runner('''
printf '%s\\n' ${_quote(scenario.message)} >&2
exit ${scenario.code}
''');
        await expectLater(run(adapter), throwsStateError);
        expect(await calls.readAsLines(), [audio]);
        expect(conversions.existsSync(), false);
      });
    }

    test('fallback decoder failure cleans work and does not invoke model again',
        () async {
      final adapter = await runner('''
printf '%s\\n' 'FUSHI_AUDIO_INPUT_UNSUPPORTED format' >&2
exit 65
''', converter: ': > "\$destination"\nexit 2');
      await expectLater(run(adapter), throwsStateError);
      expect(await calls.readAsLines(), [audio]);
      expect(
          File((await conversions.readAsLines()).single).existsSync(), false);
    });

    test('failed WAV retry terminates without a conversion loop', () async {
      final adapter = await runner('''
printf '%s\\n' 'FUSHI_AUDIO_INPUT_UNSUPPORTED format' >&2
exit 65
''', converter: ': > "\$destination"');
      await expectLater(run(adapter), throwsStateError);
      expect(await calls.readAsLines(), hasLength(2));
      expect(await conversions.readAsLines(), hasLength(1));
      expect(
          File((await conversions.readAsLines()).single).existsSync(), false);
    });

    for (final stage in ['native helper', 'fallback decoder', 'WAV retry']) {
      final fallback = stage != 'native helper';
      test('cancels and reaps $stage', () async {
        final pidFile = File('${work.path}/child-pid');
        final waiting = '''
printf '%s' "\$\$" > ${_quote(pidFile.path)}
exec /bin/sleep 30
''';
        final adapter = await runner(
            fallback
                ? '''
if [ "\$1" = ${_quote(audio)} ]; then
  printf '%s\\n' 'FUSHI_AUDIO_INPUT_UNSUPPORTED format' >&2
  exit 65
fi
$waiting
'''
                : waiting,
            converter: fallback
                ? ': > "\$destination"\n${stage == 'fallback decoder' ? waiting : ''}'
                : null);
        final cancellation = TranscribeCancellation();
        final pending = expectLater(run(adapter, cancellation: cancellation),
            throwsA(isA<TranscribeCancelled>()));
        final ready = Stopwatch()..start();
        while (!pidFile.existsSync() && ready.elapsedMilliseconds < 3000) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(pidFile.existsSync(), true);
        final pid = int.parse(await pidFile.readAsString());
        cancellation.cancel();
        await pending.timeout(const Duration(seconds: 3));
        expect((await Process.run('/bin/kill', ['-0', '$pid'])).exitCode,
            isNot(0));
        if (fallback) {
          expect(File((await conversions.readAsLines()).single).existsSync(),
              false);
        }
        expect(
            await calls.readAsLines(), hasLength(stage == 'WAV retry' ? 2 : 1));
      });
    }

    test('already cancelled request does not spawn either executable',
        () async {
      final adapter = await runner(_success);
      await expectLater(
          run(adapter, cancellation: TranscribeCancellation()..cancel()),
          throwsA(isA<TranscribeCancelled>()));
      expect(calls.existsSync(), false);
      expect(conversions.existsSync(), false);
    });

    test('invalid final JSON is still an error, not a decode fallback',
        () async {
      final adapter = await runner("printf '%s' 'invalid-json'");
      await expectLater(run(adapter), throwsA(isA<FormatException>()));
      expect(conversions.existsSync(), false);
    });
    for (final replacement in ['"start":-1', '"start":2.0']) {
      test('rejects invalid timestamps ($replacement) without a retry',
          () async {
        final adapter =
            await runner(_success.replaceFirst('"start":0.1', replacement));
        await expectLater(run(adapter), throwsA(isA<FormatException>()));
        expect(await calls.readAsLines(), [audio]);
        expect(conversions.existsSync(), false);
      });
    }
  }, skip: !Platform.isMacOS);
}
