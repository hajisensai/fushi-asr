/// HTTP 服务端：转录跑在这里，CLI 与网页都是调用方。
///
/// 设计上的两个刻意选择：
///
/// - 音频转录支持原始请求体；EPUB / 字幕对轴使用限定两个文件字段的 multipart。
/// - **响应是流式 NDJSON**，一行一个进度事件，最后一行带结果。不用 SSE：SSE 要
///   自己维护事件分帧，而这里一个连接只服务一个任务，NDJSON 已经够用，且 CLI 和
///   浏览器解析同一套。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:asr/asr.dart';
import 'package:mime/mime.dart';

import 'package:asr_server/src/web_ui.dart';

class TranscribeBackend {
  const TranscribeBackend(
      {required this.id,
      required this.name,
      required this.description,
      required this.service,
      required this.languages,
      this.unavailableReason});
  final String id;
  final String name;
  final String description;
  final TranscribeService service;
  final List<String> languages;
  final String? unavailableReason;
  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'languages': languages,
        'available': unavailableReason == null,
        'unavailableReason': unavailableReason
      };
}

/// 转录服务端。
class AsrServer {
  AsrServer({
    required this.runner,
    required this.registry,
    this.token,
    this.concurrency = 1,
    this.maxUploadBytes = 4 * 1024 * 1024 * 1024,
    this.backends,
  }) : assert(concurrency >= 1);

  final TranscribeService runner;
  final AsrModelRegistry registry;
  final List<TranscribeBackend>? backends;

  List<TranscribeBackend> get _backends =>
      backends ??
      [
        TranscribeBackend(
            id: 'default',
            name: 'ReazonSpeech · 服务器默认',
            description: '使用服务器配置的执行后端',
            service: runner,
            languages: registry.languages.map((l) => l.tag).toList())
      ];

  /// 接口令牌；null = 不鉴权（只在绑回环地址时才该这么用）。
  final String? token;

  /// 同时跑几个任务。**默认 1**：GPU 会话并发建很容易把显存撑爆，而显存不够时
  /// ORT 不报错，是溢出到主机内存后吞吐崩塌——那种"变慢了但没坏"最难查。
  final int concurrency;

  /// 单次上传上限。
  final int maxUploadBytes;

  HttpServer? _http;
  int _running = 0;
  final List<Completer<void>> _waiting = <Completer<void>>[];
  final Map<String, _ServerTask> _tasks = {};

  String _newTask() {
    final random = Random.secure();
    final id = List.generate(
            24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    final task = _ServerTask();
    _tasks[id] = task;
    task.expiry = Timer(const Duration(minutes: 5), () {
      if (!task.claimed) {
        _tasks.remove(id);
        task.finished.complete();
      }
    });
    return id;
  }

  /// 起服务，返回实际监听的地址。
  Future<Uri> start({String host = '127.0.0.1', int port = 8642}) async {
    final HttpServer http = await HttpServer.bind(host, port);
    _http = http;
    unawaited(_serve(http));
    return Uri.parse('http://$host:${http.port}/');
  }

  Future<void> stop() async {
    for (final task in _tasks.values.toList()) {
      task.cancellation.cancel();
      task.expiry?.cancel();
      if (!task.claimed && !task.finished.isCompleted) task.finished.complete();
    }
    await _http?.close(force: true);
    await Future.wait(_tasks.values.map((t) => t.finished.future));
    _tasks.clear();
    _http = null;
  }

  Future<void> _serve(HttpServer http) async {
    await for (final HttpRequest request in http) {
      unawaited(_handle(request).catchError((Object error, StackTrace stack) {
        asrLog('请求处理失败 ${request.uri}: $error\n$stack');
      }));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Headers', 'authorization');
    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }
    final String path = request.uri.path;
    try {
      if (path == '/' || path == '/index.html') {
        response.headers.contentType = ContentType.html;
        response.add(utf8.encode(buildWebUi()));
        await response.close();
        return;
      }
      if (path == '/v1/health') {
        await _json(response, <String, Object?>{'ok': true});
        return;
      }
      if (!_authorized(request)) {
        response.statusCode = HttpStatus.unauthorized;
        await _json(response, <String, Object?>{'error': '需要 Bearer 令牌'});
        return;
      }
      if (path == '/v1/models' && request.method == 'GET') {
        await _json(response, <String, Object?>{
          'languages': <Object>[
            for (final AsrLanguage l in registry.languages)
              <String, String>{'tag': l.tag, 'nativeName': l.nativeName},
          ],
          'packs': <Object>[
            for (final AsrModelPack p in registry.packs)
              <String, Object?>{
                'id': p.id,
                'displayName': p.displayName,
                'architecture': p.architecture.name,
                'languages': <String>[
                  for (final AsrLanguage l in p.languages) l.tag
                ],
              },
          ],
        });
        return;
      }
      if (path == '/v1/backends' && request.method == 'GET') {
        await _json(
            response, {'backends': _backends.map((b) => b.toJson()).toList()});
        return;
      }
      if (path == '/v1/jobs' && request.method == 'POST') {
        if (_tasks.length >= 1024) {
          response.statusCode = HttpStatus.tooManyRequests;
          await _json(response, {'error': '任务过多，请稍后重试'});
          return;
        }
        await _json(response, {'jobId': _newTask()});
        return;
      }
      final cancelMatch =
          RegExp(r'^/v1/jobs/([a-f0-9]{48})/cancel$').firstMatch(path);
      if (cancelMatch != null && request.method == 'POST') {
        final id = cancelMatch.group(1)!;
        final task = _tasks[id];
        if (task == null) {
          await _json(response, {'status': 'finished'});
          return;
        }
        task.cancellation.cancel();
        task.expiry?.cancel();
        if (!task.claimed) {
          _tasks.remove(id);
          if (!task.finished.isCompleted) task.finished.complete();
        }
        // Acknowledgement means the slot and resources really are released.
        await task.finished.future;
        await _json(response, {'status': 'cancelled'});
        return;
      }
      if (path == '/v1/transcribe' && request.method == 'POST') {
        await _transcribe(request, response);
        return;
      }
      if (path == '/v1/retime' && request.method == 'POST') {
        await _transcribe(request, response, retiming: true);
        return;
      }
      response.statusCode = HttpStatus.notFound;
      await _json(response, <String, Object?>{'error': '没有这个接口：$path'});
    } catch (error) {
      asrLog('请求处理失败 ${request.uri}: $error');
      try {
        response.statusCode = HttpStatus.internalServerError;
        await _json(response, <String, Object?>{'error': '$error'});
      } catch (_) {
        // 响应已经开始写了（流式路径）：状态码改不了，但**必须把连接关掉**。
        // 不关的话客户端会一直等下去——比拿到一个错误码难查得多。
        try {
          await response.close();
        } catch (_) {
          // 连关都失败：底层连接已经没了，没有别的补救。
        }
      }
    }
  }

  bool _authorized(HttpRequest request) {
    final String? expected = token;
    if (expected == null) return true;
    final String? header =
        request.headers.value(HttpHeaders.authorizationHeader);
    return header == 'Bearer $expected';
  }

  Future<void> _transcribe(HttpRequest request, HttpResponse response,
      {bool retiming = false}) async {
    final String? tag = request.uri.queryParameters['language'];
    final AsrLanguage? language = AsrLanguage.fromTag(tag);
    if (language == null) {
      response.statusCode = HttpStatus.badRequest;
      await _json(response, <String, Object?>{
        'error': '缺 language 或不认识："$tag"',
        'languages': <String>[
          for (final AsrLanguage l in registry.languages) l.tag,
        ],
      });
      return;
    }
    final String formatName = request.uri.queryParameters['format'] ?? 'srt';
    final SubtitleFormat? format = SubtitleFormat.fromName(formatName);
    if (format == null) {
      response.statusCode = HttpStatus.badRequest;
      await _json(response, <String, Object?>{'error': '未知格式 $formatName'});
      return;
    }

    final engineId = request.uri.queryParameters['engine'];
    TranscribeBackend? backend;
    if (engineId != null) {
      for (final candidate in _backends) {
        if (candidate.id == engineId) backend = candidate;
      }
      if (backend == null ||
          backend.unavailableReason != null ||
          !backend.languages.contains(language.tag)) {
        response.statusCode = HttpStatus.badRequest;
        await _json(response, {
          'error': backend?.unavailableReason ?? '未知或不支持此语言的转录方案：$engineId'
        });
        return;
      }
    }

    final requestedJob = request.uri.queryParameters['jobId'];
    final id = requestedJob ?? _newTask();
    final task = _tasks[id];
    if (task == null || task.claimed) {
      response.statusCode = HttpStatus.conflict;
      await _json(response, {'error': '任务不存在、已终止或已提交'});
      return;
    }
    task.claimed = true;
    task.expiry?.cancel();
    final cancellation = task.cancellation;
    // Socket failures also stop computation rather than leaving orphan jobs.
    unawaited(
        response.done.then<void>((_) {}, onError: (Object _, StackTrace __) {
      cancellation.cancel();
    }));
    Directory? work;
    try {
      final temp = await Directory.systemTemp.createTemp('asr_upload_');
      work = temp;
      final File upload = File('${temp.path}${Platform.pathSeparator}'
          // Unique basename also prevents completed Reazon jobs from satisfying a
          // new upload with the same name/size. Every UI run performs real work.
          '${temp.uri.pathSegments.where((s) => s.isNotEmpty).last}-'
          '${_safeName(request.uri.queryParameters['filename'])}');
      final attachment =
          File('${temp.path}/${retiming ? 'subtitle.txt' : 'book.epub'}');
      bool withBook;
      List<SubtitleCue>? subtitleCues;
      final subtitleWatch = Stopwatch();
      try {
        final withAttachment = await _receiveUpload(
            request, upload, attachment, cancellation,
            retiming: retiming);
        withBook = withAttachment && !retiming;
        if (retiming) {
          subtitleWatch.start();
          cancellation.throwIfCancelled();
          final parsed = await cancellableCompute(
              _subtitleReadTask(attachment.path), cancellation);
          if (parsed.$2 != null) throw FormatException(parsed.$2!);
          subtitleCues = parsed.$1!;
          cancellation.throwIfCancelled();
          subtitleWatch.stop();
        }
      } on FormatException catch (error) {
        response.statusCode = HttpStatus.badRequest;
        await _json(response, {'error': error.message});
        return;
      } on MimeMultipartException {
        response.statusCode = HttpStatus.badRequest;
        await _json(response, {'error': 'multipart 上传内容不完整或格式无效'});
        return;
      }

      response.statusCode = HttpStatus.ok;
      response.headers.contentType =
          ContentType('application', 'x-ndjson', charset: 'utf-8');
      response.bufferOutput = false;
      // **必须显式编码成 UTF-8 字节**，不能用 `response.write(String)`：
      // `HttpResponse` 的 `IOSink` 默认编码是 **latin1**，只要字幕里有一个非
      // ASCII 字符（日文、中文、带重音的欧洲语言……）就会抛
      // `Invalid argument (string): Contains invalid characters`。而这一抛发生在
      // 流式写开始之后，状态码已经发出去改不了，表现出来就是「连接永远不关」，
      // 客户端一直等——最难查的那种失败。
      void emit(Map<String, Object?> json) {
        response.add(utf8.encode('${jsonEncode(json)}\n'));
      }

      // Send before waiting so clients distinguish queueing from uploading.
      emit(<String, Object?>{'phase': 'queued', 'fraction': 0});
      await response.flush();
      bool acquired = false;
      try {
        await _acquire(cancellation);
        acquired = true;
        cancellation.throwIfCancelled();
        final pipelineWatch = Stopwatch()..start();
        if (subtitleCues != null) {
          emit({
            'phase': 'subtitle',
            'detail': '已解析 ${subtitleCues.length} 条字幕，保留原文并校准时间轴'
          });
        }
        EpubBook? book;
        if (withBook) {
          emit({'phase': 'book', 'detail': '按 EPUB 阅读顺序解析正文与 ruby 注音'});
          book = await readCancellableEpubBook(attachment.path, cancellation);
        }
        final bookReadMs = pipelineWatch.elapsedMilliseconds;
        final transcribeWatch = Stopwatch()..start();
        final TranscribeOutcome outcome =
            await (backend?.service ?? runner).run(
          audioPaths: <String>[upload.path],
          language: language,
          format: format,
          cancellation: cancellation,
          onProgress: (TranscribeProgress p) => emit(p.toJson()),
        );
        transcribeWatch.stop();
        cancellation.throwIfCancelled();
        BookAlignedSubtitles? aligned;
        RetimedSubtitles? retimed;
        final alignmentWatch = Stopwatch()..start();
        if (book != null) {
          emit({
            'phase': 'align',
            'detail': '正文匹配、锚点回填与句界校准（${book.sections.length} 个正文片段）'
          });
          aligned = await alignTranscriptionWithBook(book, outcome, format,
              cancellation: cancellation);
        }
        if (subtitleCues != null) {
          emit({
            'phase': 'retime',
            'detail': '匹配语音锚点并校准 ${subtitleCues.length} 条字幕时间轴'
          });
          retimed = await retimeSubtitles(subtitleCues, outcome, format,
              cancellation: cancellation);
        }
        alignmentWatch.stop();
        pipelineWatch.stop();
        cancellation.throwIfCancelled();
        emit(<String, Object?>{
          'phase': 'result',
          'fraction': 1,
          'format': format.name,
          'cueCount':
              retimed?.cueCount ?? aligned?.cueCount ?? outcome.cues.length,
          'audioMs': outcome.audioMs,
          'elapsedMs': pipelineWatch.elapsedMilliseconds +
              subtitleWatch.elapsedMilliseconds,
          'transcribeMs': transcribeWatch.elapsedMilliseconds,
          'bookReadMs': bookReadMs,
          if (retiming) 'subtitleReadMs': subtitleWatch.elapsedMilliseconds,
          if (aligned != null)
            'alignment': {
              ...aligned.stats,
              'elapsedMs': alignmentWatch.elapsedMilliseconds
            },
          if (retimed != null)
            'retiming': {
              ...retimed.stats,
              'elapsedMs': alignmentWatch.elapsedMilliseconds
            },
          'provider': outcome.providerLabel,
          'fellBack': outcome.provider?.didFallBack ?? false,
          'engine': backend?.id ?? 'default',
          'engineName': backend?.name ?? '服务器默认',
          'text': retimed?.text ?? aligned?.text ?? outcome.text,
          if (aligned != null || retimed != null) 'rawText': outcome.text,
        });
      } on TranscribeCancelled {
        emit({'phase': 'cancelled', 'detail': '任务已终止，运算资源已释放'});
      } catch (error) {
        // 已经开始流式写了，改不了状态码，所以错误也走 NDJSON 的最后一行。
        // 客户端的判据必须是「有没有收到 result 行」，不是 HTTP 状态码。
        emit(<String, Object?>{'phase': 'error', 'error': '$error'});
      } finally {
        if (acquired) _release();
      }
      await response.close();
    } on TranscribeCancelled {
      // Cancellation while uploading: no inference has started yet.
      response.statusCode = HttpStatus.ok;
      response.headers.contentType =
          ContentType('application', 'x-ndjson', charset: 'utf-8');
      response.add(utf8.encode('${jsonEncode({'phase': 'cancelled'})}\n'));
      await response.close();
    } finally {
      if (work != null && work.existsSync()) {
        try {
          work.deleteSync(recursive: true);
        } on FileSystemException {
          // 转录进程可能还占着；留给系统清临时目录。
        }
      }
      _tasks.remove(id);
      if (!task.finished.isCompleted) task.finished.complete();
    }
  }

  Future<bool> _receiveUpload(HttpRequest request, File audio, File attachment,
      TranscribeCancellation cancellation,
      {bool retiming = false}) async {
    int total = 0;
    final attachmentName = retiming ? 'subtitle' : 'epub';
    final attachmentLimit = retiming ? maxSubtitleBytes : maxEpubBytes;
    StreamIterator<List<int>>? activeUpload;
    Future<void> save(Stream<List<int>> stream, File file, int limit) async {
      int size = 0;
      final sink = file.openWrite();
      final chunks = StreamIterator(stream);
      activeUpload = chunks;
      try {
        while (await chunks.moveNext()) {
          final chunk = chunks.current;
          cancellation.throwIfCancelled();
          size += chunk.length;
          total += chunk.length;
          if (size > limit || total > maxUploadBytes + attachmentLimit) {
            throw FormatException(retiming
                ? '上传超过上限（字幕 8 MiB，音视频按服务器上限）'
                : '上传超过上限（EPUB 64 MiB，音频按服务器上限）');
          }
          sink.add(chunk);
          await sink.flush();
        }
      } finally {
        await chunks.cancel();
        await sink.close();
        activeUpload = null;
      }
      if (size == 0) throw const FormatException('请求体或上传文件是空的');
    }

    final contentType = request.headers.contentType;
    if (contentType?.mimeType != 'multipart/form-data') {
      if (retiming) {
        throw const FormatException('字幕对轴必须使用 multipart 同时上传 audio 和 subtitle');
      }
      await save(request, audio, maxUploadBytes);
      return false;
    }
    final boundary = contentType!.parameters['boundary'];
    if (boundary == null || boundary.isEmpty || boundary.length > 200) {
      throw const FormatException('缺少或无效 multipart boundary');
    }
    final seen = <String>{};
    StreamIterator<MimeMultipart>? parts;
    await _guardMultipart(() async {
      final incoming = parts = StreamIterator(request
          .cast<List<int>>()
          .transform(MimeMultipartTransformer(boundary)));
      try {
        while (await incoming.moveNext()) {
          final part = incoming.current;
          HeaderValue disposition;
          try {
            disposition =
                HeaderValue.parse(part.headers['content-disposition'] ?? '');
          } on HttpException {
            throw const FormatException('上传文件的 Content-Disposition 无效');
          }
          final name = disposition.parameters['name'];
          if (!{'audio', attachmentName}.contains(name) || !seen.add(name!)) {
            throw FormatException('只允许唯一 audio 和 $attachmentName 文件');
          }
          if (retiming) {
            final filename = disposition.parameters['filename'];
            if (disposition.value != 'form-data' ||
                filename == null ||
                filename.trim().isEmpty) {
              throw const FormatException('audio 和 subtitle 必须是带文件名的上传文件');
            }
            if (name == 'subtitle' &&
                !RegExp(r'\.(srt|vtt)$', caseSensitive: false)
                    .hasMatch(filename)) {
              throw const FormatException('字幕仅支持 UTF-8 编码的 SRT 或 VTT 文件');
            }
          }
          await save(part, name == 'audio' ? audio : attachment,
              name == 'audio' ? maxUploadBytes : attachmentLimit);
        }
      } finally {
        await incoming.cancel();
      }
    }, () async {
      try {
        await activeUpload?.cancel();
      } finally {
        await parts?.cancel();
      }
    });
    if (!seen.containsAll(['audio', attachmentName])) {
      throw FormatException('必须同时上传 audio 和 $attachmentName');
    }
    return true;
  }

  Future<void> _acquire(TranscribeCancellation cancellation) async {
    cancellation.throwIfCancelled();
    if (_running < concurrency) {
      _running++;
      return;
    }
    final Completer<void> waiter = Completer<void>();
    _waiting.add(waiter);
    final detach = cancellation.listen(() {
      if (_waiting.remove(waiter)) {
        waiter.completeError(const TranscribeCancelled());
      }
    });
    try {
      await waiter.future;
    } finally {
      detach();
    }
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      // Transfer ownership directly; a new request cannot steal the freed slot.
      _waiting.removeAt(0).complete();
    } else {
      _running--;
    }
  }

  Future<void> _json(HttpResponse response, Map<String, Object?> json) async {
    response.headers.contentType = ContentType.json;
    response.add(utf8.encode(jsonEncode(json)));
    await response.close();
  }
}

/// Keep preflight parsing cancellable without capturing request/socket state.
/// Validation failures travel as values so they remain HTTP 400 across isolates.
Future<(List<SubtitleCue>?, String?)> Function() _subtitleReadTask(
        String path) =>
    () async {
      String input;
      try {
        input = utf8.decode(await File(path).readAsBytes());
      } on FormatException {
        return (null, '字幕必须使用 UTF-8 编码，请转换编码后重新上传');
      }
      try {
        return (parseRetimingSubtitles(input), null);
      } on FormatException catch (error) {
        return (null, error.message.toString());
      }
    };

/// mime 2.0 can throw malformed-header errors from its source callback instead
/// of adding a stream error. Cancel both iterators to unblock file writes, then
/// report that error only after the upload routine has closed its resources.
Future<void> _guardMultipart(
    Future<void> Function() receive, Future<void> Function() cancel) {
  final result = Completer<void>();
  Object? parserError;
  StackTrace? parserStack;
  runZonedGuarded(() {
    receive().then((_) {
      if (result.isCompleted) return;
      if (parserError != null) {
        result.completeError(parserError!, parserStack);
      } else {
        result.complete();
      }
    }, onError: (Object error, StackTrace stack) {
      if (!result.isCompleted) {
        result.completeError(parserError ?? error, parserStack ?? stack);
      }
    });
  }, (error, stack) {
    if (parserError != null || result.isCompleted) return;
    parserError = error;
    parserStack = stack;
    unawaited(Future<void>.sync(cancel).then<void>((_) {},
        onError: (Object _, StackTrace __) {
      // A cleanup failure must not reenter the error zone or strand the request.
      if (!result.isCompleted) result.completeError(parserError!, parserStack);
    }));
  });
  return result.future;
}

class _ServerTask {
  final cancellation = TranscribeCancellation();
  final finished = Completer<void>();
  bool claimed = false;
  Timer? expiry;
}

/// 上传文件名只用来给 ffmpeg 一个像样的扩展名；一律剥路径分隔符。
///
/// 直接拿用户给的名字拼路径是经典的目录穿越（`../../etc/passwd`）。这里不需要
/// 保留原名，所以最简单的正确做法是只留 basename 里的安全字符。
String _safeName(String? raw) {
  if (raw == null || raw.isEmpty) return 'upload.bin';
  final String base = raw.split(RegExp(r'[\\/]')).last;
  final String cleaned = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'upload.bin';
  return cleaned.length > 120
      ? cleaned.substring(cleaned.length - 120)
      : cleaned;
}
