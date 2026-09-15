import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';

import 'support.dart' as f;

void main() {
  const codec = BackupRecordCodec();
  final savedAward = Operation<Object>(
    id: OperationId(f.uuid(5)),
    kind: OperationKind.saveItem,
    committedAt: f.event,
    requestFingerprint: 'synthetic-request-5',
    committedResult: f.award(),
  );

  test('round-trips every product record through portable JSON', () {
    final values = [
      f.group(),
      f.quest(),
      f.award(),
      f.settings,
      savedAward,
      f.entry(f.award(), const TimeDimension(), 60000),
      f.session(f.quest()),
    ];
    for (final value in values) {
      final decoded = codec.fromJson(codec.toJson(value), f.metadata);
      expect(decoded.runtimeType, value.runtimeType, reason: '$value');
      expect(codec.toJson(decoded), codec.toJson(value));
    }
  });

  test('reconstructs inert clock anchors and derived deadlines', () {
    final running = f.session(f.quest(), status: SessionStatus.running);
    final restored =
        codec.fromJson(codec.toJson(running), f.metadata) as Session;
    expect(restored.startedAt.bootId, restoredClockBootId);
    expect(restored.startedAt.monotonic.value, 0);
    expect(restored.checkpoint.monotonic.value, 0);
    // The export format keeps the checkpoint instant and remaining time, so
    // the original deadline is derived exactly.
    expect(restored.deadlineUtc, running.deadlineUtc);
    for (final interval in restored.intervals) {
      expect(interval.startedAt.bootId, restoredClockBootId);
      expect(interval.endedAt.monotonic.value, 0);
    }

    final ended = f.session(f.quest(), status: SessionStatus.ended);
    expect(
      (codec.fromJson(codec.toJson(ended), f.metadata) as Session).deadlineUtc,
      isNull,
    );
  });

  test('session mutations regain a cancellation-only intent', () {
    final session = f.session(f.quest(), status: SessionStatus.paused);
    final mutation = SessionMutation(
      session: session,
      economy: EconomicState(
        operationId: f.operation(session.itemSnapshot).id,
        wallet: WalletProjection(revision: Revision(1), balances: f.amounts(0)),
        awards: const [],
        activeSession: session,
        entries: const [],
        achievements: const [],
      ),
      notificationIntent: NotificationIntent(
        sessionId: session.id,
        sessionRevision: session.revision,
        completionId: session.completionId,
        deadlineUtc: null,
        completionChimeHandled: true,
      ),
    );
    final restored =
        codec.fromJson(codec.toJson(mutation), f.metadata) as SessionMutation;
    expect(restored.session.status, SessionStatus.paused);
    expect(restored.notificationIntent.deadlineUtc, isNull);
    expect(restored.notificationIntent.completionChimeHandled, false);
    expect(restored.notificationIntent.sessionId, session.id);
  });

  test('operation results must match their persisted command kind', () {
    final record = codec.toJson(savedAward);
    expect(codec.fromJson(record, f.metadata).runtimeType, Operation<Object>);
    for (final mutated in [
      {...record, 'kind': 'exportBackup'},
      {...record, 'kind': 'unknown'},
      {...record, 'result': codec.toJson(f.settings)},
    ]) {
      expect(
        () => codec.fromJson(mutated, f.metadata),
        throwsA(isA<InvalidBackup>()),
      );
    }
  });

  test('out-of-range or mistyped values are rejected as invalid backups', () {
    final record = codec.toJson(f.group());
    for (final mutated in [
      {...record, 'revision': '-1'},
      {...record, 'revision': 'x'},
      {...record, 'name': 3},
    ]) {
      expect(
        () => codec.fromJson(mutated, f.metadata),
        throwsA(isA<InvalidBackup>()),
      );
    }
    // Unsupported pinned currencies cannot be interpreted faithfully.
    final budget = codec.toJson(
      BudgetAmount(BudgetCurrency.fromMetadata('USD', f.metadata), 100),
    );
    expect(
      () => codec.fromJson({...budget, 'currency': 'XXX'}, f.metadata),
      throwsA(isA<InvalidBackup>()),
    );
  });
}
