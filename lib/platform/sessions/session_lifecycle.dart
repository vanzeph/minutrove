import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../../domain/domain.dart';
import 'session_recovery.dart';

/// Own one instance per open store. Await start() before exposing session
/// commands, observe results for errors, and dispose before closing the store.
/// Timers only request reconciliation; they never measure or credit activity.
final class SessionLifecycle with WidgetsBindingObserver {
  SessionLifecycle({
    required this.recovery,
    required this.clock,
    this.checkpointEvery = const Duration(seconds: 30),
    OperationId Function()? operationId,
  }) : _operationId = operationId ?? _newOperationId {
    if (checkpointEvery <= Duration.zero) {
      throw ArgumentError.value(checkpointEvery, 'checkpointEvery');
    }
  }

  final SessionRecovery recovery;
  final Clock clock;
  final Duration checkpointEvery;
  final OperationId Function() _operationId;
  final _results = StreamController<Result<SessionMutation?>>.broadcast();
  Stream<Result<SessionMutation?>> get results => _results.stream;
  StreamSubscription<Session?>? _subscription;
  Timer? _checkpoint;
  Timer? _deadline;
  bool _started = false;
  bool _disposed = false;
  bool _foreground = true;
  int _generation = 0;
  Future<Result<SessionMutation?>>? _pending;

  Future<Result<SessionMutation?>> start() async {
    if (_disposed) throw StateError('Session lifecycle disposed');
    if (!_started) {
      _started = true;
      WidgetsBinding.instance.addObserver(this);
      _foreground =
          WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      _subscription = recovery.sessions.watchActiveSession().listen(
        _schedule,
        onError: (Object _) =>
            _publish(const Failure(StorageUnavailable(retryable: true))),
      );
    }
    return reconcile();
  }

  /// Concurrent lifecycle/deadline callbacks share one in-flight command.
  /// After a failure, a new attempt reads the durable anchors again.
  Future<Result<SessionMutation?>> reconcile() {
    if (_disposed) throw StateError('Session lifecycle disposed');
    return _pending ??= _recover();
  }

  Future<Result<SessionMutation?>> _recover() async {
    try {
      final result = await recovery.reconcile(operationId: _operationId());
      _publish(result);
      return result;
    } finally {
      _pending = null;
    }
  }

  void _publish(Result<SessionMutation?> result) {
    if (!_disposed) _results.add(result);
  }

  Future<void> _schedule(Session? session) async {
    final generation = ++_generation;
    _checkpoint?.cancel();
    _deadline?.cancel();
    if (_disposed || !_foreground || session?.status != SessionStatus.running) {
      return;
    }
    _checkpoint = Timer.periodic(checkpointEvery, (_) => reconcile());
    try {
      final reading = await clock.now();
      if (_disposed || generation != _generation || !_foreground) return;
      final remaining = remainingSessionMilliseconds(session!, reading);
      _deadline = Timer(Duration(milliseconds: remaining), reconcile);
    } catch (_) {
      _publish(const Failure(StorageUnavailable(retryable: true)));
      // The periodic checkpoint remains available for a bounded later retry.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed || !_started) return;
    _foreground = state == AppLifecycleState.resumed;
    _generation++;
    _deadline?.cancel();
    _checkpoint?.cancel();
    // Android/iOS may kill the process without this callback. Startup recovery
    // uses the last committed anchors and does not depend on this write.
    unawaited(
      reconcile().then((_) async {
        if (_disposed || !_foreground) return;
        final read = await recovery.store.read((r) => r.activeSession());
        if (read case Success<Session?>(:final value)) {
          await _schedule(value);
        }
      }),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _deadline?.cancel();
    _checkpoint?.cancel();
    await _subscription?.cancel();
    await _pending;
    await _results.close();
  }
}

OperationId _newOperationId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = bytes[6] & 0x0f | 0x40;
  bytes[8] = bytes[8] & 0x3f | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return OperationId(
    '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
    '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}',
  );
}
