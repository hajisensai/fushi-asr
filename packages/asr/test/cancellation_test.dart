import 'dart:async';
import 'dart:io';
import 'package:fushi_asr/asr.dart';
import 'package:test/test.dart';

int _expensive() {
  final watch = Stopwatch()..start();
  while (watch.elapsed.inSeconds < 30) {}
  return 7;
}

void main() {
  test('cancellation listeners are removable, idempotent and late-safe', () {
    final token = TranscribeCancellation();
    var count = 0;
    token.listen(() => count++);
    token.listen(() => count += 10)();
    token.cancel();
    token.cancel();
    token.listen(() => count++);
    expect(count, 2);
    expect(token.throwIfCancelled, throwsA(isA<TranscribeCancelled>()));
  });
  test('pure Dart isolate is terminated, not just its awaiting UI', () async {
    final token = TranscribeCancellation();
    final pending = expectLater(cancellableCompute(_expensive, token),
        throwsA(isA<TranscribeCancelled>()));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    token.cancel();
    await pending.timeout(const Duration(seconds: 2));
    expect(await cancellableCompute(() => 42, TranscribeCancellation()), 42);
  });
  test('child process cancellation reaps the exact child', () async {
    final token = TranscribeCancellation();
    final child = await Process.start('/bin/sleep', ['30']);
    final detach = cancelProcess(child, token);
    token.cancel();
    expect(await child.exitCode.timeout(const Duration(seconds: 3)), isNot(0));
    detach();
  }, skip: Platform.isWindows);
  test('cancelled runner never starts a model', () async {
    final token = TranscribeCancellation()..cancel();
    final runner = TranscribeRunner(
        registry: AsrModelRegistry.builtin(), forceCoreMl: true);
    await expectLater(
        runner.run(
            audioPaths: [],
            language: AsrLanguage.japanese, audioProfile: AsrAudioProfile.cleanSpeech,
            cancellation: token),
        throwsA(isA<TranscribeCancelled>()));
    await runner.close();
  });
}
