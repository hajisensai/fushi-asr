import 'dart:io';
import 'package:asr/asr.dart';
import 'package:test/test.dart';

void main() {
  test('close during initial spawn drains the accepted request', () async {
    final runner = TranscribeRunner(registry: AsrModelRegistry.builtin(),
      forceCoreMl: true, missingModel: MissingModelPolicy.fail);
    final result = expectLater(runner.run(
      audioPaths: ['/nonexistent-asr-close-test.wav'],
      language: AsrLanguage.japanese), throwsStateError);
    await Future.wait([runner.close(), runner.close(), result]);
  }, skip: !Platform.isMacOS);

  test(
      'CoreML worker propagates failures, accepts subsequent jobs, drains close',
      () async {
    final runner = TranscribeRunner(
        registry: AsrModelRegistry.builtin(),
        forceCoreMl: true,
        missingModel: MissingModelPolicy.fail);
    addTearDown(runner.close);
    Future<void> fail(int i) async {
      await expectLater(
          runner.run(
              audioPaths: ['/nonexistent-asr-test-$i.wav'],
              language: AsrLanguage.japanese),
          throwsA(isA<StateError>()));
    }

    await Future.wait([fail(1), fail(2)]);
    await fail(3);
    final last = fail(4);
    await runner.close();
    await last;
    await runner.close();
    await expectLater(
        runner.run(audioPaths: [], language: AsrLanguage.japanese),
        throwsStateError);
  }, skip: !Platform.isMacOS);

  test('CPU/CoreML conflict rejects before spawning a worker', () async {
    final runner = TranscribeRunner(
        registry: AsrModelRegistry.builtin(),
        forceCpu: true,
        forceCoreMl: true);
    await expectLater(
        runner.run(audioPaths: [], language: AsrLanguage.japanese),
        throwsArgumentError);
    await runner.close();
  });
}
