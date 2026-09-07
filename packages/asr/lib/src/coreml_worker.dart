part of 'transcribe_runner.dart';

// Native sessions never cross the isolate boundary. A future queue serializes
// requests, including shutdown, so concurrent HTTP requests cannot share a lease.
class _CoreMlWorker {
  _CoreMlWorker(this._inbox);
  final ReceivePort _inbox;
  final _ready = Completer<SendPort>();
  late final SendPort _port;
  final _stopped = Completer<void>();
  final Map<int, Completer<TranscribeOutcome>> _pending = {};
  final Map<int, void Function(TranscribeProgress)> _progress = {};
  final Map<int, (Object, StackTrace)> _callbackErrors = {};
  int _nextId = 0;
  bool _closing = false;

  static Future<_CoreMlWorker> spawn(AsrModelRegistry registry, Directory? root,
      MissingModelPolicy policy) async {
    final inbox = ReceivePort();
    final worker = _CoreMlWorker(inbox);
    inbox.listen(worker._receive);
    try {
      await Isolate.spawn(
          _coreMlWorkerMain, (inbox.sendPort, registry, root?.path, policy),
          onError: inbox.sendPort,
          onExit: inbox.sendPort,
          debugName: 'macos-coreml-worker');
      await worker._ready.future;
      return worker;
    } catch (_) {
      inbox.close();
      rethrow;
    }
  }

  void _receive(dynamic message) {
    if (message is SendPort) {
      _port = message;
      _ready.complete(message);
    } else if (message is _CoreMlReply) {
      if (message.value is TranscribeProgress) {
        // A UI callback must not break the worker protocol or leak a request.
        try {
          _progress[message.id]?.call(message.value as TranscribeProgress);
        } catch (error, stack) {
          _callbackErrors[message.id] = (error, stack);
          _progress.remove(message.id);
        }
      } else {
        final pending = _pending.remove(message.id);
        _progress.remove(message.id);
        final callbackError = _callbackErrors.remove(message.id);
        if (callbackError != null) {
          pending?.completeError(callbackError.$1, callbackError.$2);
        } else if (message.value is TranscribeOutcome) {
          pending?.complete(message.value as TranscribeOutcome);
        } else if (message.value is TranscribeCancelled) {
          pending?.completeError(const TranscribeCancelled());
        } else {
          pending?.completeError(StateError(message.value.toString()));
        }
      }
    } else if (message == null || message is List) {
      final error = StateError(
          'CoreML worker exited${message == null ? '' : ': $message'}');
      if (!_ready.isCompleted) _ready.completeError(error);
      for (final pending in _pending.values) {
        pending.completeError(error);
      }
      _pending.clear();
      _progress.clear();
      _callbackErrors.clear();
      _closing = true;
      if (!_stopped.isCompleted) _stopped.complete();
      _inbox.close();
    }
  }

  Future<TranscribeOutcome> run(
      List<String> paths,
      AsrLanguage language,
      SubtitleFormat format,
      void Function(TranscribeProgress)? progress,
      TranscribeCancellation? cancellation) async {
    cancellation?.throwIfCancelled();
    if (_closing) throw StateError('CoreML worker is closing');
    final id = _nextId++;
    final result = Completer<TranscribeOutcome>();
    _pending[id] = result;
    if (progress != null) _progress[id] = progress;
    _port.send(_CoreMlRequest(id, List.of(paths), language, format));
    final detach = cancellation?.listen(() => _port.send(_CoreMlCancel(id)));
    try {
      return await result.future;
    } finally {
      detach?.call();
    }
  }

  Future<void> close() async {
    if (!_closing) {
      _closing = true;
      _port.send(null);
    }
    await _stopped.future;
  }
}

class _CoreMlRequest {
  _CoreMlRequest(this.id, this.paths, this.language, this.format);
  final int id;
  final List<String> paths;
  final AsrLanguage language;
  final SubtitleFormat format;
}

class _CoreMlReply {
  _CoreMlReply(this.id, this.value);
  final int id;
  final Object value;
}

class _CoreMlCancel {
  const _CoreMlCancel(this.id);
  final int id;
}

Future<void> _coreMlWorkerMain(
    (SendPort, AsrModelRegistry, String?, MissingModelPolicy) config) async {
  final (replies, registry, root, policy) = config;
  final requests = ReceivePort();
  final cache = ReusingOnnxSessionFactory(FfiOnnxSessionFactory());
  final runner = TranscribeRunner(
      registry: registry,
      dataRoot: root == null ? null : Directory(root),
      forceCoreMl: true,
      reuseCoreMlSessions: false,
      missingModel: policy);
  AsrLanguage? previousLanguage;
  replies.send(requests.sendPort);
  final tokens = <int, TranscribeCancellation>{};
  Future<void> queue = Future.value();
  final done = Completer<void>();
  requests.listen((message) {
    if (message is _CoreMlCancel) {
      tokens[message.id]?.cancel();
      return;
    }
    if (message == null) {
      queue.then((_) => done.complete());
      return;
    }
    final request = message as _CoreMlRequest;
    final cancellation = TranscribeCancellation();
    tokens[request.id] = cancellation;
    queue = queue.then((_) async {
      try {
        cancellation.throwIfCancelled();
        // One language resident: switching models must not accumulate weights.
        if (previousLanguage != request.language) await cache.clear();
        previousLanguage = request.language;
        final result = await runner._run(
            audioPaths: request.paths,
            language: request.language,
            format: request.format,
            sessionFactory: cache,
            cancellation: cancellation,
            onProgress: (p) => replies.send(_CoreMlReply(request.id, p)));
        replies.send(_CoreMlReply(request.id, result));
      } on TranscribeCancelled {
        // Sessions have been returned by _run's finally; safe to reuse them.
        replies.send(_CoreMlReply(request.id, const TranscribeCancelled()));
      } catch (error, stack) {
        await cache.clear();
        replies.send(_CoreMlReply(request.id, '$error\n$stack'));
      } finally {
        tokens.remove(request.id);
      }
    });
  });
  try {
    await done.future;
  } finally {
    requests.close();
    await cache.close();
  }
}
