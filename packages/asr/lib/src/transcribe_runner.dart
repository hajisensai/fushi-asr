/// 本机转录的装配与执行：CLI 与服务端共用这一层。
///
/// 存在的理由：`asr transcribe` 和 `POST /v1/transcribe` 要做的事逐字相同——装配
/// 注册表、开服务、按需下模型、跑、把 SRT 转成请求的格式。两处各写一遍必然漂移。
library;

import 'dart:async';
import 'dart:io';

import 'package:asr_core/asr_core.dart';
import 'package:asr_onnx_ffi/asr_onnx_ffi.dart';

import 'package:asr/src/subtitle_format.dart';

/// 一次转录的进度回报。
class TranscribeProgress {
  const TranscribeProgress({
    required this.phase,
    this.processedMs = 0,
    this.totalMs = 0,
    this.detail = '',
  });

  /// `download` / `load` / `transcribe` / `done`。
  final String phase;
  final int processedMs;
  final int totalMs;
  final String detail;

  double get fraction => totalMs <= 0 ? 0 : (processedMs / totalMs).clamp(0, 1);

  Map<String, Object?> toJson() => <String, Object?>{
        'phase': phase,
        'processedMs': processedMs,
        'totalMs': totalMs,
        'fraction': fraction,
        if (detail.isNotEmpty) 'detail': detail,
      };
}

/// 转录结果。
class TranscribeOutcome {
  const TranscribeOutcome({
    required this.text,
    required this.cues,
    required this.provider,
    required this.elapsed,
    required this.audioMs,
  });

  /// 按请求格式渲染好的字幕文本。
  final String text;
  final List<SubtitleCue> cues;

  /// 编码器真正落到的 EP（含降级后的结果）。
  final OnnxProviderResolution provider;
  final Duration elapsed;
  final int audioMs;
}

/// 缺模型时的处理方式。
enum MissingModelPolicy {
  /// 自动下载（CLI 与服务端默认：无人值守）。
  download,

  /// 直接报错，让调用方决定。
  fail,
}

/// 转录能力的抽象。
///
/// 服务端只依赖这个接口而不是具体的 [TranscribeRunner]：一来可以在不碰真模型的
/// 前提下测服务端自己的行为（编码、错误路径、并发闸门），二来将来要接别的执行
/// 后端也不用动服务端。
abstract interface class TranscribeService {
  Future<TranscribeOutcome> run({
    required List<String> audioPaths,
    required AsrLanguage language,
    SubtitleFormat format,
    void Function(TranscribeProgress progress)? onProgress,
  });
}

/// 本机转录器。
class TranscribeRunner implements TranscribeService {
  TranscribeRunner({
    required this.registry,
    this.dataRoot,
    this.forceCpu = false,
    this.missingModel = MissingModelPolicy.download,
  });

  final AsrModelRegistry registry;

  /// 模型与任务目录的根；null 走 `asrSupportRootDirectory()` 的默认解析。
  final Directory? dataRoot;

  final bool forceCpu;
  final MissingModelPolicy missingModel;

  /// 转录 [audioPaths]，把字幕按 [format] 渲染出来。
  ///
  /// [onProgress] 会被密集调用（每个进度事件一次），调用方自己节流。
  @override
  Future<TranscribeOutcome> run({
    required List<String> audioPaths,
    required AsrLanguage language,
    SubtitleFormat format = SubtitleFormat.srt,
    void Function(TranscribeProgress progress)? onProgress,
  }) async {
    asrModelRegistry = registry;
    final Directory? root = dataRoot;
    if (root != null) {
      asrSupportRootResolver = () async => root;
    }
    for (final String path in audioPaths) {
      if (!File(path).existsSync()) {
        throw FileSystemException('音频文件不存在', path);
      }
    }

    final AsrTranscriptionService service = AsrTranscriptionService(
      backend: const AsrIsolateBackend(buildFactory: buildFfiOnnxFactory),
    );
    final AsrAccelerationPreference preference = forceCpu
        ? AsrAccelerationPreference.cpuOnly
        : AsrAccelerationPreference.auto;

    final AsrTranscribePlan plan = await service.plan(
      language: language,
      preference: preference,
    );
    final String? probeError = plan.probeError;
    if (probeError != null) {
      // EP 探测失败是一条真实的降级路径（有 GPU 也会退成 CPU）。不吞：整本转录
      // 按 CPU 速度跑完却不知道为什么慢，是最难查的那种"没坏但不对"。
      onProgress?.call(TranscribeProgress(
        phase: 'load',
        detail: 'EP 探测失败，按 CPU 推荐：$probeError',
      ));
    }

    if (!plan.modelReady) {
      if (missingModel == MissingModelPolicy.fail) {
        throw StateError(
          '${language.tag} 的模型还没下全（还差 ${_mb(plan.bytesToDownload)}）；'
          '先跑 `asr models pull -l ${language.tag}`',
        );
      }
      await for (final ModelDownloadEvent e in service.downloadModel(
        language: language,
        variant: plan.variant,
      )) {
        onProgress?.call(TranscribeProgress(
          phase: 'download',
          processedMs: e.receivedBytes,
          totalMs: e.totalBytes,
          detail: e.fileName,
        ));
      }
    }

    onProgress?.call(const TranscribeProgress(phase: 'load'));
    final Stopwatch watch = Stopwatch()..start();
    final AsrRunningTranscription running = await service.start(
      audioPaths: audioPaths,
      language: language,
      variant: plan.variant,
      preference: preference,
    );
    try {
      AsrTranscribeResult? finished;
      await for (final AsrTranscribeEvent event in running.run()) {
        switch (event) {
          case AsrTranscribeProgressEvent(:final AsrTranscribeProgress progress):
            onProgress?.call(TranscribeProgress(
              phase: 'transcribe',
              processedMs: progress.processedMs,
              totalMs: progress.totalMs,
            ));
          case AsrTranscribePausedEvent():
            throw StateError('转录被暂停 —— 非交互运行下不该发生');
          case AsrTranscribeFinishedEvent(:final AsrTranscribeResult result):
            finished = result;
        }
      }
      watch.stop();
      if (finished == null) {
        throw StateError('转录结束但没有产出结果');
      }
      final String srt = await File(finished.srtPath).readAsString();
      final List<SubtitleCue> cues = parseSrt(srt);
      onProgress?.call(TranscribeProgress(
        phase: 'done',
        processedMs: finished.totalMs,
        totalMs: finished.totalMs,
      ));
      return TranscribeOutcome(
        // srt 直接用产物原文，不经解析再渲染一遍：那样会把核心写出来的东西
        // 换成我们的渲染结果，出了差异很难说清是谁的。
        text: format == SubtitleFormat.srt ? srt : renderSubtitles(cues, format),
        cues: cues,
        provider: running.encoderResolution,
        elapsed: watch.elapsed,
        audioMs: finished.totalMs,
      );
    } finally {
      asrShutdownTrace('runner: dispose start');
      await running.dispose();
      asrShutdownTrace('runner: dispose done');
    }
  }
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
