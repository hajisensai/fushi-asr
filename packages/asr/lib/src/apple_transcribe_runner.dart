import 'dart:convert';
import 'dart:io';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_asr_subtitles/asr_subtitles.dart';
import 'transcribe_runner.dart';


typedef _AppleNativeOutput = ({
  int exitCode,
  String stdout,
  String stderr,
  bool unsupportedInput
});

/// macOS 26+ SpeechTranscriber helper. Decoding and native inference are local.
/// No ONNX provider is reported for Apple's native model.
class AppleTranscribeRunner implements TranscribeService {
  AppleTranscribeRunner(
      {required this.executablePath,
      this.ffmpegExecutablePath,
      bool? useCompatibilityPcm})
      : useCompatibilityPcm = useCompatibilityPcm ??
            Platform.environment['ASR_APPLE_COMPAT_PCM'] == '1';
  final String executablePath;
  final String? ffmpegExecutablePath;

  /// Reproduce the previous ffmpeg/downmix/resample input path when diagnosing
  /// decoder differences or files that fail after AVAudioFile has opened them.
  final bool useCompatibilityPcm;

  Future<String?> unavailableReason() async {
    if (!Platform.isMacOS) return '仅支持 macOS 26 及以上';
    if (!File(executablePath).existsSync()) return 'Apple 转录程序未构建，请运行启动脚本';
    try {
      final probe = await Process.run(executablePath, ['--status']);
      if (probe.exitCode != 0) return 'Apple 转录不可用：${probe.stderr}';
      final status = jsonDecode(probe.stdout as String) as Map;
      return status['ready'] == true ? null : '请先安装 Apple 日语语音资源（启动脚本会检查）';
    } catch (e) {
      return 'Apple 转录检查失败：$e';
    }
  }

  @override
  Future<TranscribeOutcome> run({
    required List<String> audioPaths,
    required AsrLanguage language,
    // 原生 Apple 引擎自己做端点检测，不经本仓的 VAD 切段：这里收下但不使用。
    required AsrAudioProfile audioProfile,
    SubtitleFormat format = SubtitleFormat.srt,
    void Function(TranscribeProgress)? onProgress,
    TranscribeCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    if (!Platform.isMacOS || language != AsrLanguage.japanese) {
      throw UnsupportedError('当前 Apple 转录适配支持 macOS 日语文件');
    }
    if (audioPaths.length != 1) throw ArgumentError('Apple 转录每次接受一个文件');
    final watch = Stopwatch()..start();
    Directory? work;
    Future<_AppleNativeOutput> runCompatible(String detail) async {
      cancellation?.throwIfCancelled();
      onProgress?.call(TranscribeProgress(phase: 'load', detail: detail));
      final directory = await Directory.systemTemp.createTemp('asr_apple_pcm_');
      work = directory;
      final wav = '${directory.path}/audio.wav';
      await _decode(audioPaths.single, wav, cancellation);
      return _runNative(wav, onProgress, cancellation);
    }

    try {
      _AppleNativeOutput native;
      if (useCompatibilityPcm) {
        native = await runCompatible('Apple 兼容模式，解码音频');
      } else {
        onProgress?.call(
            const TranscribeProgress(
              phase: 'load',
              detail: 'Apple 原生读取音频',
              detailCode: 'appleDecoding',
            ));
        native = await _runNative(audioPaths.single, onProgress, cancellation);
        if (native.exitCode == 65 && native.unsupportedInput) {
          native = await runCompatible('原生解码不支持此文件，使用兼容解码');
        }
      }
      if (native.exitCode != 0) throw StateError('Apple 转录失败：${native.stderr}');
      final json = jsonDecode(native.stdout) as Map<String, dynamic>;
      final cues = <SubtitleCue>[];
      for (final segment in json['segments'] as List) {
        final text = (segment['text'] as String).trim();
        if (text.isEmpty) continue;
        final start = ((segment['start'] as num).toDouble() * 1000).round();
        final end = ((segment['end'] as num).toDouble() * 1000).round();
        if (start < 0 || end < start) throw FormatException('Apple 返回无效时间戳');
        cues.add(SubtitleCue(
            index: cues.length + 1, startMs: start, endMs: end, text: text));
      }
      if (cues.isEmpty) throw StateError('Apple 未生成字幕');
      watch.stop();
      final audioMs =
          ((json['audio_seconds'] as num).toDouble() * 1000).round();
      return TranscribeOutcome(
          text: renderSubtitles(cues, format),
          cues: cues,
          engine: 'apple-speechtranscriber',
          elapsed: watch.elapsed,
          audioMs: audioMs);
    } finally {
      if (work != null) await work!.delete(recursive: true);
    }
  }

  Future<_AppleNativeOutput> _runNative(
      String path,
      void Function(TranscribeProgress)? onProgress,
      TranscribeCancellation? cancellation) async {
    cancellation?.throwIfCancelled();
    final process = await Process.start(executablePath, [path]);
    final detach = cancelProcess(process, cancellation);
    final errors = StringBuffer();
    var unsupportedInput = false;
    // Drain both pipes concurrently so long books cannot block on a full pipe.
    final output = utf8.decodeStream(process.stdout);
    final diagnostics = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
      if (line.startsWith('FUSHI_PROGRESS ')) {
        try {
          final value = jsonDecode(line.substring(15));
          if (value is Map &&
              value['processedMs'] is num &&
              value['totalMs'] is num &&
              (value['processedMs'] as num).isFinite &&
              (value['totalMs'] as num).isFinite) {
            onProgress?.call(TranscribeProgress(
                phase: 'transcribe',
                processedMs: (value['processedMs'] as num).toInt(),
                totalMs: (value['totalMs'] as num).toInt(),
                detail: 'Apple SpeechTranscriber · 已确认片段进度',
                detailCode: 'appleConfirmed'));
          }
        } on FormatException {
          // Ignore malformed diagnostics, not final results.
        }
      } else {
        if (line.startsWith('FUSHI_AUDIO_INPUT_UNSUPPORTED ')) {
          unsupportedInput = true;
        }
        if (errors.length < 16000) errors.writeln(line);
      }
    });
    try {
      final values = await Future.wait<Object>([
        output,
        diagnostics.then<Object>((_) => true),
        process.exitCode,
      ]);
      cancellation?.throwIfCancelled();
      return (
        exitCode: values[2] as int,
        stdout: values[0] as String,
        stderr: errors.toString(),
        unsupportedInput: unsupportedInput
      );
    } finally {
      process.kill();
      await process.exitCode;
      detach();
    }
  }

  Future<void> _decode(
      String path, String wav, TranscribeCancellation? cancellation) async {
    cancellation?.throwIfCancelled();
    final converter = await Process.start(
        ffmpegExecutablePath ?? Platform.environment['ASR_FFMPEG'] ?? 'ffmpeg',
        [
          '-v',
          'error',
          '-nostdin',
          '-i',
          path,
          '-map',
          '0:a:0',
          '-ac',
          '1',
          '-ar',
          '16000',
          '-c:a',
          'pcm_s16le',
          wav,
        ]);
    final detach = cancelProcess(converter, cancellation);
    try {
      final values = await Future.wait<Object>([
        converter.exitCode,
        utf8.decodeStream(converter.stderr),
        converter.stdout.drain().then<Object>((_) => true),
      ]);
      cancellation?.throwIfCancelled();
      if (values[0] != 0) throw StateError('音频解码失败：${values[1]}');
    } finally {
      converter.kill();
      await converter.exitCode;
      detach();
    }
  }
}
