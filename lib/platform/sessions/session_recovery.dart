import '../../data/sqlite_store.dart';
import '../../domain/domain.dart';
import 'recovery_diagnostics.dart';

/// Recovers the persisted global slot, including a paused session. A concurrent
/// end/replacement can only make reconciliation of the previously read ID a
/// harmless terminal no-op; it can never settle a newly started session instead.
final class SessionRecovery {
  const SessionRecovery({
    required this.store,
    required this.sessions,
    required this.recordDiagnostic,
  });
  final SqliteStore store;
  final SessionRepository sessions;
  final RecordRecoveryDiagnostic recordDiagnostic;

  Future<Result<SessionMutation?>> reconcile({
    required OperationId operationId,
  }) async {
    final read = await store.read((records) => records.activeSession());
    if (read case Failure<Session?>(:final error)) {
      await _record(RecoveryDiagnostic.recoveryUnavailable);
      return Failure(error);
    }
    final previous = (read as Success<Session?>).value;
    if (previous == null) return const Success(null);
    final result = await sessions.reconcileSession(
      operationId: operationId,
      sessionId: previous.id,
    );
    switch (result) {
      case Failure<SessionMutation>(:final error):
        await _record(RecoveryDiagnostic.recoveryUnavailable);
        return Failure(error);
      case Success<SessionMutation>(:final value):
        final current = value.session;
        // A replay or paused no-op must not emit a second diagnostic.
        if (current.revision.value > previous.revision.value &&
            previous.status == SessionStatus.running) {
          final before = previous.checkpoint;
          final after = current.checkpoint;
          if (before.bootId != after.bootId) {
            await _record(RecoveryDiagnostic.bootChanged);
          } else {
            final drift =
                after.utc.difference(before.utc).inMilliseconds -
                (after.monotonic.value - before.monotonic.value);
            // Allow normal native sampling jitter, never log subsecond drift.
            if (drift.abs() > 1000) {
              await _record(
                drift > 0
                    ? RecoveryDiagnostic.wallClockForward
                    : RecoveryDiagnostic.wallClockBackward,
              );
            }
          }
        }
        return Success(value);
    }
  }

  Future<void> _record(RecoveryDiagnostic event) async {
    try {
      await recordDiagnostic(event);
    } catch (_) {
      // Callers may supply another local sink. It cannot roll back settlement.
    }
  }
}
