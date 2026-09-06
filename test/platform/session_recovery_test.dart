import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/platform/sessions/recovery_diagnostics.dart';
import 'package:minutrove/platform/sessions/session_lifecycle.dart';
import 'package:minutrove/platform/sessions/session_recovery.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/fault_database.dart';
import '../data/support.dart' as f;
import '../support/session_fixtures.dart';

class AsyncClock implements Clock {
  final source = SessionClock();
  Completer<ClockReading>? pending;
  bool fail = false;
  int calls = 0;
  @override
  Future<ClockReading> now() async {
    calls++;
    if (fail) throw const StorageUnavailable(retryable: true);
    return pending == null ? source.now() : pending!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late SqliteStore store;
  late SqliteSessionRepository sessions;
  late SessionRecovery recovery;
  late AsyncClock clock;
  late Item quest;
  late Session started;
  var serial = 1000;
  OperationId op() => OperationId(f.uuid(serial++));
  final events = <RecoveryDiagnostic>[];

  setUp(() async {
    events.clear();
    dir = await Directory.systemTemp.createTemp('minutrove-recovery-');
    store = f.success(
      await SqliteStore.open(
        path: '${dir.path}/test.db',
        factory: databaseFactoryFfi,
        currencies: f.metadata,
        initialSettings: f.settings,
      ),
    );
    clock = AsyncClock();
    final calendar = SessionCalendar();
    sessions = SqliteSessionRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
    recovery = SessionRecovery(
      store: store,
      sessions: sessions,
      recordDiagnostic: (event) async => events.add(event),
    );
    quest = f.success(
      await SqliteItemRepository(
        store: store,
        clock: clock,
        calendar: calendar,
      ).saveItem(
        operationId: op(),
        item: configuredQuest(seconds: 1),
        expectedRevision: null,
      ),
    );
    started = f
        .success(
          await sessions.startSession(
            operationId: op(),
            itemId: quest.id,
            expectedItemRevision: quest.revision,
            conflictChoice: SessionConflictChoice.cancel,
          ),
        )
        .session;
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  test('awaited clock error rolls back without an operation; retry and replay are exact', () async {
    final before = await dump('${dir.path}/test.db');
    final id = op();
    clock.fail = true;
    final failed = await recovery.reconcile(operationId: id);
    expect((failed as Failure).error, isA<StorageUnavailable>());
    expect(await dump('${dir.path}/test.db'), before);
    expect(events, [RecoveryDiagnostic.recoveryUnavailable]);
    clock.fail = false;
    clock.source.advance(500);
    final recovered = f.success(await recovery.reconcile(operationId: id))!;
    expect(recovered.session.settled.value, 500);
    final committed = await dump('${dir.path}/test.db');
    clock.fail = true;
    expect(
      f
          .success(
            await sessions.reconcileSession(
              operationId: id,
              sessionId: started.id,
            ),
          )
          .session
          .settled
          .value,
      500,
    );
    expect(await dump('${dir.path}/test.db'), committed);
  });

  test('clock wait holds the command queue; concurrent recovery settles at most once', () async {
    clock.source.advance(1000);
    final pending = clock.pending = Completer<ClockReading>();
    final first = recovery.reconcile(operationId: op());
    final second = recovery.reconcile(operationId: op());
    var published = false;
    unawaited(first.then((_) => published = true));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(published, isFalse);
    pending.complete(clock.source.now());
    clock.pending = null;
    f.success(await first);
    f.success(await second);
    final completed = f.success(await sessions.getSession(started.id))!;
    expect(completed.status, SessionStatus.completed);
    expect(completed.settled.value, 1000);
    expect(
      f.success(await store.read((r) => r.wallet())).balances.coins.units,
      33333,
    );
    expect(
      f.success(await store.read((r) => r.projectionMismatches())),
      isEmpty,
    );
  });

  test(
    'diagnostic output is committed-only, bounded, and cannot fail economics',
    () async {
      final log = LocalRecoveryDiagnostics(File('${dir.path}/recovery.log'));
      await File('${dir.path}/recovery.log')
          .writeAsString('private injected text\n');
      await Future.wait(
        List.generate(40, (_) => log.record(RecoveryDiagnostic.bootChanged)),
      );
      expect(await log.file.readAsLines(), List.filled(32, 'bootChanged'));
      final unavailable = LocalRecoveryDiagnostics(
        File('${dir.path}/missing/log'),
      );
      await unavailable.record(RecoveryDiagnostic.bootChanged);
      final brokenSink = SessionRecovery(
        store: store,
        sessions: sessions,
        recordDiagnostic: (_) async => throw StateError('Sink failed'),
      );
      clock.source.boot = 'new-boot';
      clock.source.utc = clock.source.utc.add(const Duration(days: 1));
      final completed = f.success(
        await brokenSink.reconcile(operationId: op()),
      )!;
      expect(completed.session.status, SessionStatus.completed);
    },
  );

  test('lifecycle startup, background, resume, pause and deadline use persisted state', () async {
    final lifecycle = SessionLifecycle(
      recovery: recovery,
      clock: clock,
      checkpointEvery: const Duration(milliseconds: 40),
      operationId: op,
    );
    final results = <Result<SessionMutation?>>[];
    final subscription = lifecycle.results.listen(results.add);
    try {
      f.success(await lifecycle.start());
      clock.source.advance(250);
      lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
      f.success(await lifecycle.reconcile());
      expect(
        f.success(await sessions.getSession(started.id))!.settled.value,
        250,
      );
      clock.source.advance(250);
      lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
      f.success(await lifecycle.reconcile());
      var current = f.success(await sessions.getSession(started.id))!;
      expect(current.settled.value, 500);
      current = f
          .success(
            await sessions.pauseSession(
              operationId: op(),
              sessionId: current.id,
              expectedRevision: current.revision,
            ),
          )
          .session;
      clock.source.advance(60000);
      f.success(await lifecycle.reconcile());
      expect(
        f.success(await sessions.getSession(started.id))!.settled.value,
        500,
      );
      f.success(
        await sessions.resumeSession(
          operationId: op(),
          sessionId: current.id,
          expectedRevision: current.revision,
        ),
      );
      final completed = lifecycle.results.firstWhere(
        (r) =>
            r is Success<SessionMutation?> &&
            r.value?.session.status == SessionStatus.completed,
      );
      clock.source.advance(500);
      final result = f.success(
        await completed.timeout(const Duration(seconds: 3)),
      )!;
      expect(result.session.settled.value, 1000);
      expect(result.session.completionId, started.completionId);
      expect(results.whereType<Failure<SessionMutation?>>(), isEmpty);
    } finally {
      await lifecycle.dispose();
      await subscription.cancel();
    }
  });

  test(
    'duplicate callbacks coalesce and dispose drains a pending recovery',
    () async {
      final lifecycle = SessionLifecycle(
        recovery: recovery,
        clock: clock,
        operationId: op,
      );
      clock.source.advance(200);
      final pending = clock.pending = Completer<ClockReading>();
      final first = lifecycle.reconcile();
      expect(identical(first, lifecycle.reconcile()), isTrue);
      var disposed = false;
      final closing = lifecycle.dispose().then((_) => disposed = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(disposed, isFalse);
      pending.complete(clock.source.now());
      clock.pending = null;
      f.success(await first);
      await closing;
      expect(
        f.success(await sessions.getSession(started.id))!.settled.value,
        200,
      );
      expect(() => lifecycle.reconcile(), throwsStateError);
    },
  );
}
