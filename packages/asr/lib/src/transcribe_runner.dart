/// 本机转录的装配与执行：CLI 与服务端共用这一层。
///
/// 存在的理由：`fushi-subs transcribe` 和 `POST /v1/transcribe` 要做的事逐字相同——装配
/// 注册表、开服务、按需下模型、跑、把 SRT 转成请求的格式。两处各写一遍必然漂移。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_asr_onnx_ffi/asr_onnx_ffi.dart';

import 'package:fushi_asr/src/subtitle_format.dart';
import 'cancellation.dart';

part 'coreml_worker.dart';

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
    this.provider,
    this.engine = 'reazonspeech',
    this.tokenTimings,
    this.decodeStats,
    required this.elapsed,
    required this.audioMs,
  });

  /// 按请求格式渲染好的字幕文本。
  final String text;
  final List<SubtitleCue> cues;

  /// 编码器真正落到的 EP（含降级后的结果）。
  final OnnxProviderResolution? provider;

  /// Native engines do not have an ONNX execution provider.
  final String engine;
  final List<AsrCueTokenTiming>? tokenTimings;

  /// Diagnostic elapsed timings; asynchronous stages may overlap.
  final AsrDecodeStats? decodeStats;
  String get providerLabel => provider?.effective.name ?? engine;
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
    TranscribeCancellation? cancellation,
  });
}

/// 本机转录器。
class TranscribeRunner implements TranscribeService {
  TranscribeRunner({
    required this.registry,
    this.dataRoot,
    this.forceCpu = false,
    this.forceCoreMl = false,
    this.reuseCoreMlSessions = true,
    this.missingModel = MissingModelPolicy.download,
  });

  final AsrModelRegistry registry;

  /// 模型与任务目录的根；null 走 `asrSupportRootDirectory()` 的默认解析。
  final Directory? dataRoot;

  final bool forceCpu;

  /// Experimental macOS FP32 encoder backend; see MACOS_COREML.md benchmarks.
  final bool forceCoreMl;

  /// macOS only. Keep sessions in an isolated, serial worker until [close].
  final bool reuseCoreMlSessions;
  final MissingModelPolicy missingModel;
  Future<_CoreMlWorker>? _worker;
  bool _closed = false;
  Future<void>? _closing;

  /// Stop accepting work, drain queued CoreML jobs, and release native models.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    final worker = _worker;
    if (worker != null) await (await worker).close();
  }

  /// 转录 [audioPaths]，把字幕按 [format] 渲染出来。
  ///
  /// [onProgress] 会被密集调用（每个进度事件一次），调用方自己节流。
  @override
  Future<TranscribeOutcome> run({
    required List<String> audioPaths,
    required AsrLanguage language,
    SubtitleFormat format = SubtitleFormat.srt,
    void Function(TranscribeProgress progress)? onProgress,
    TranscribeCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    if (_closed) throw StateError('TranscribeRunner is closed');
    if (forceCpu && forceCoreMl) {
      throw ArgumentError('CPU and CoreML cannot both be requested');
    }
    if (forceCoreMl && reuseCoreMlSessions && Platform.isMacOS) {
      final worker = await (_worker ??=
          _CoreMlWorker.spawn(registry, dataRoot, missingModel));
      return worker.run(audioPaths, language, format, onProgress, cancellation);
    }
    return _run(
        audioPaths: audioPaths,
        language: language,
        format: format,
        onProgress: onProgress,
        cancellation: cancellation);
  }

  Future<TranscribeOutcome> _run({
    required List<String> audioPaths,
    required AsrLanguage language,
    required SubtitleFormat format,
    void Function(TranscribeProgress progress)? onProgress,
    OnnxSessionFactory? sessionFactory,
    TranscribeCancellation? cancellation,
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

    // ONNX Runtime 必须在任何会用到它的东西之前就位：plan() 要探 EP，推理
    // isolate 要装模型，两者都得先有动态库。Windows 上缺库、或只搜得到系统
    // 目录那份旧 ORT 时按需下载（17.9 MB，带 DirectML EP）。进度按模型下载
    // 同一个契约回报，前端不用认第二种事件；已有可用运行时时这一步不发事件、
    // 也不访问网络。
    cancellation?.throwIfCancelled();
    await for (final ModelDownloadEvent e in ensureOrtRuntime()) {
      cancellation?.throwIfCancelled();
      onProgress?.call(TranscribeProgress(
        phase: 'download',
        processedMs: e.receivedBytes,
        totalMs: e.totalBytes,
        detail: 'ONNX Runtime $kOrtPackageVersion（${e.fileName}）',
      ));
    }

    final AsrTranscriptionService service = AsrTranscriptionService(
      // managedRuntimeDir 是 per-isolate 静态字段，过不了边界：不把它显式
      // 送进去，推理 isolate 会重新解析候选并撞回系统目录里的旧 ORT。
      backend: AsrIsolateBackend(
        buildFactory: buildFfiOnnxFactory,
        bootstrap: adoptOrtManagedRuntimeDir,
        bootstrapArg: OrtRuntime.managedRuntimeDir,
      ),
      loader: sessionFactory == null
          ? null
          : AsrEngineLoader(factory: sessionFactory),
      runInIsolate: sessionFactory == null,
      greedySessions: _macOsSetting('ASR_MACOS_GREEDY_SESSIONS'),
      greedyIntraOpThreads: _macOsSetting('ASR_MACOS_GREEDY_THREADS'),
      batchSize: _macOsSetting('ASR_MACOS_BATCH_SIZE'),
      // CPU/INT8 checkpoints must not satisfy an explicit FP32/CoreML run.
      jobsRoot: forceCoreMl
          ? () async => Directory(
              '${(await asrSupportRootDirectory()).path}/asr_jobs/coreml-fp32')
          : null,
    );
    final AsrAccelerationPreference preference = forceCoreMl
        ? AsrAccelerationPreference.coreml
        : forceCpu
            ? AsrAccelerationPreference.cpuOnly
            : AsrAccelerationPreference.auto;

    final AsrTranscribePlan plan = await service.plan(
      language: language,
      preference: preference,
    );
    if (forceCoreMl && plan.variant != AsrEncoderVariant.fp32) {
      throw StateError(
          'CoreML requires FP32, but this model exceeds the configured GPU memory budget');
    }
    final String? probeError = plan.probeError;
    if (probeError != null) {
      // EP 探测失败是一条真实的降级路径（有 GPU 也会退成 CPU）。不吞：整本转录
      // 按 CPU 速度跑完却不知道为什么慢，是最难查的那种"没坏但不对"。
      onProgress?.call(TranscribeProgress(
        phase: 'load',
        detail: 'EP 探测失败，按 CPU 推荐：$probeError',
      ));
    }

    cancellation?.throwIfCancelled();
    if (!plan.modelReady) {
      if (missingModel == MissingModelPolicy.fail) {
        throw StateError(
          '${language.tag} 的模型还没下全（还差 ${_mb(plan.bytesToDownload)}）；'
          '先跑 `fushi-subs models pull -l ${language.tag} --variant ${plan.variant.name}`',
        );
      }
      await for (final ModelDownloadEvent e in service.downloadModel(
        language: language,
        variant: plan.variant,
      )) {
        cancellation?.throwIfCancelled();
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
    final detach =
        cancellation?.listen(() => running.requestPause(discardPending: true));
    try {
      cancellation?.throwIfCancelled();
      // Model construction has completed. Start the frontend's ASR clock now,
      // not at the first chunk-complete event (which may be minutes of audio).
      onProgress?.call(const TranscribeProgress(
        phase: 'transcribe',
        detail: '模型已就绪；按音频块回报进度，首块完成前剩余时间待估算',
      ));
      AsrTranscribeResult? finished;
      await for (final AsrTranscribeEvent event in running.run()) {
        switch (event) {
          case AsrTranscribeProgressEvent(
              :final AsrTranscribeProgress progress
            ):
            if (cancellation?.isCancelled == true) continue;
            onProgress?.call(TranscribeProgress(
              phase: 'transcribe',
              processedMs: progress.processedMs,
              totalMs: progress.totalMs,
            ));
          case AsrTranscribePausedEvent():
            cancellation?.throwIfCancelled();
            throw StateError('转录被暂停 —— 非交互运行下不该发生');
          case AsrTranscribeFinishedEvent(:final AsrTranscribeResult result):
            finished = result;
        }
      }
      cancellation?.throwIfCancelled();
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
        text:
            format == SubtitleFormat.srt ? srt : renderSubtitles(cues, format),
        cues: cues,
        tokenTimings: await AsrTranscriptionService.readCueTokenTimings(
            finished.srtPath,
            expectedCount: cues.length),
        provider: running.encoderResolution,
        decodeStats: running.decodeStats,
        elapsed: watch.elapsed,
        audioMs: finished.totalMs,
      );
    } finally {
      detach?.call();
      asrShutdownTrace('runner: dispose start');
      await running.dispose();
      if (cancellation?.isCancelled == true) {
        await service.discard(audioPaths, language);
      }
      asrShutdownTrace('runner: dispose done');
    }
  }
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

int? _macOsSetting(String name) {
  if (!Platform.isMacOS) return null;
  final raw = Platform.environment[name];
  if (raw == null) return null;
  final value = int.tryParse(raw);
  if (value == null || value < 1 || value > 64) {
    throw ArgumentError('$name must be 1..64');
  }
  return value;
}
