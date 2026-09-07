import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart';

/// Explicitly owned, single-isolate pool. Each borrower gets an exclusive lease;
/// closing a lease returns it to the pool, closing the pool frees native memory.
/// Callers must finish all jobs before [close]. Not enabled by the default FFI
/// factory: the macOS worker is the only production consumer.
class ReusingOnnxSessionFactory implements OnnxSessionFactory {
  ReusingOnnxSessionFactory(this.delegate);

  final OnnxSessionFactory delegate;
  final Map<String, List<_Entry>> _entries = {};
  final Set<_Lease> _leases = {};
  int _creating = 0;
  bool _closed = false;

  @override
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    void Function(OnnxProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    if (_closed) throw StateError('Session pool is closed');
    _creating++;
    try {
      return await _createSession(modelPath,
          providers: providers,
          onProviderResolved: onProviderResolved,
          intraOpNumThreads: intraOpNumThreads,
          freeDimensionOverrides: freeDimensionOverrides);
    } finally {
      _creating--;
    }
  }

  Future<OnnxSession> _createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    void Function(OnnxProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    final file = File(modelPath);
    final stat = await file.stat();
    final shapes = freeDimensionOverrides?.entries.toList()
      ?..sort((a, b) => a.key.compareTo(b.key));
    final key = jsonEncode([
      file.absolute.path,
      stat.size,
      stat.modified.microsecondsSinceEpoch,
      stat.changed.microsecondsSinceEpoch,
      providers.map((p) => p.name).toList(),
      intraOpNumThreads,
      if (shapes != null) {for (final shape in shapes) shape.key: shape.value}
    ]);
    final entries = _entries.putIfAbsent(key, () => []);
    for (final entry in entries) {
      if (!entry.busy) {
        onProviderResolved?.call(entry.resolution);
        entry.busy = true;
        return _lease(entry);
      }
    }
    OnnxProviderResolution? resolution;
    final session = await delegate.createSession(modelPath,
        providers: providers,
        intraOpNumThreads: intraOpNumThreads,
        freeDimensionOverrides: freeDimensionOverrides,
        onProviderResolved: (value) {
      resolution = value;
    });
    final resolved = resolution ??
        OnnxProviderResolution(
            requested: providers,
            effective: providers.isEmpty
                ? OnnxExecutionProvider.cpu
                : providers.first);
    try {
      onProviderResolved?.call(resolved);
    } catch (_) {
      await session.close();
      rethrow;
    }
    final entry = _Entry(session, resolved);
    // A transient CoreML failure must be retried on the next job.
    if (!resolved.didFallBack) entries.add(entry);
    return _lease(entry, retire: resolved.didFallBack);
  }

  _Lease _lease(_Entry entry, {bool retire = false}) {
    final lease = _Lease(entry, _leases.remove, retire: retire);
    _leases.add(lease);
    return lease;
  }

  /// Drop idle sessions (e.g. when switching language), without closing the pool.
  Future<void> clear() async {
    if (_leases.isNotEmpty || _creating != 0) {
      throw StateError('Cannot clear a session pool with active leases');
    }
    final entries = _entries.values.expand((v) => v).toList();
    _entries.clear();
    for (final entry in entries) {
      await entry.session.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await clear();
    } catch (_) {
      _closed = false;
      rethrow;
    }
  }

  @override
  Future<Set<OnnxExecutionProvider>> availableAcceleratedProviders() =>
      delegate.availableAcceleratedProviders();
  @override
  Future<int?> deviceMemoryBudgetBytes() => delegate.deviceMemoryBudgetBytes();
}

class _Entry {
  _Entry(this.session, this.resolution);
  final OnnxSession session;
  final OnnxProviderResolution resolution;
  bool busy = true;
}

class _Lease implements OnnxSession {
  _Lease(this.entry, this.onClose, {this.retire = false});
  final _Entry entry;
  final void Function(_Lease) onClose;
  final bool retire;
  bool closed = false;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) {
    if (closed) throw StateError('Session lease is closed');
    return entry.session.run(inputs);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    entry.busy = false;
    onClose(this);
    if (retire) await entry.session.close();
  }
}
