import 'dart:async';
import 'dart:io';
import 'dart:isolate';

class TranscribeCancelled implements Exception {
  const TranscribeCancelled();
  @override
  String toString() => '任务已终止';
}

/// Per-request, idempotent cancellation. Completion is acknowledged only after
/// the runner has released its resources, not when the button is clicked.
class TranscribeCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>{};
  bool get isCancelled => _cancelled;
  void throwIfCancelled() {
    if (_cancelled) throw const TranscribeCancelled();
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  void Function() listen(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }
}

/// Used only for pure Dart work (EPUB parsing / alignment), never ORT sessions.
Future<T> cancellableCompute<T>(FutureOr<T> Function() compute,
    TranscribeCancellation? cancellation) async {
  cancellation?.throwIfCancelled();
  if (cancellation == null) return Isolate.run(compute);
  final messages = ReceivePort();
  final result = Completer<T>();
  final exited = Completer<void>();
  final subscription = messages.listen((message) {
    if (message == null) {
      if (!result.isCompleted) {
        result.completeError(cancellation.isCancelled
            ? const TranscribeCancelled()
            : StateError('后台计算意外结束'));
      }
      if (!exited.isCompleted) exited.complete();
    } else if (!result.isCompleted && message is (bool, Object?)) {
      if (message.$1) {
        result.complete(message.$2 as T);
      } else {
        result.completeError(StateError(message.$2.toString()));
      }
    } else if (!result.isCompleted && message is List) {
      result.completeError(StateError(message.toString()));
    }
  });
  Isolate? isolate;
  void Function()? detach;
  // Attach an error handler before spawn/onExit can complete the future.
  final handled = result.future;
  unawaited(handled.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  try {
    isolate = await Isolate.spawn(
        _computeEntry<T>, (messages.sendPort, compute),
        onError: messages.sendPort, onExit: messages.sendPort);
    detach =
        cancellation.listen(() => isolate?.kill(priority: Isolate.immediate));
    final value = await handled;
    cancellation.throwIfCancelled();
    return value;
  } finally {
    detach?.call();
    if (isolate != null) {
      await exited.future;
    }
    await subscription.cancel();
    messages.close();
  }
}

Future<void> _computeEntry<T>((SendPort, FutureOr<T> Function()) args) async {
  try {
    args.$1.send((true, await args.$2()));
  } catch (error) {
    args.$1.send((false, error.toString()));
  }
}

/// Kill only the child belonging to this request; always reap it in the caller.
void Function() cancelProcess(Process process, TranscribeCancellation? token) {
  Timer? force;
  final detach = token?.listen(() {
    process.kill();
    force = Timer(
        const Duration(seconds: 2), () => process.kill(ProcessSignal.sigkill));
  });
  return () {
    detach?.call();
    force?.cancel();
  };
}
