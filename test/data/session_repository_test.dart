import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fault_database.dart';
import 'support.dart' as f;
import '../support/session_fixtures.dart';

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqliteStore store;
  late SqliteSessionRepository repo;
  late SessionClock clock;
  final calendar = SessionCalendar();
  var serial = 1000;
  OperationId op() => OperationId(f.uuid(serial++));
  Future<void> open({DatabaseFactory? factory}) async {
    store = f.success(
      await SqliteStore.open(
        path: '${dir.path}/test.db',
        factory: factory ?? databaseFactoryFfi,
        currencies: f.metadata,
        initialSettings: f.settings,
      ),
    );
    repo = SqliteSessionRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
  }

  Future<Item> save(Item item, {bool create = true}) async => f.success(
    await SqliteItemRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    ).saveItem(
      operationId: op(),
      item: item,
      expectedRevision: create ? null : item.revision,
    ),
  );
  Future<SessionMutation> start(
    Item item, {
    OperationId? id,
    SessionConflictChoice choice = SessionConflictChoice.cancel,
  }) async => f.success(
    await repo.startSession(
      operationId: id ?? op(),
      itemId: item.id,
      expectedItemRevision: item.revision,
      conflictChoice: choice,
    ),
  );
  Future<SessionMutation> pause(Session s, {OperationId? id}) async =>
      f.success(
        await repo.pauseSession(
          operationId: id ?? op(),
          sessionId: s.id,
          expectedRevision: s.revision,
        ),
      );
  Future<SessionMutation> resume(Session s) async => f.success(
    await repo.resumeSession(
      operationId: op(),
      sessionId: s.id,
      expectedRevision: s.revision,
    ),
  );
  Future<SessionMutation> end(Session s, {OperationId? id}) async => f.success(
    await repo.endSession(
      operationId: id ?? op(),
      sessionId: s.id,
      expectedRevision: s.revision,
    ),
  );
  Future<SessionMutation> reconcile(Session s, {OperationId? id}) async =>
      f.success(
        await repo.reconcileSession(operationId: id ?? op(), sessionId: s.id),
      );
  Future<void> grant(Item award, int time, {int budget = 0}) async {
    final id = op();
    f.success(
      await CommandCoordinator(store).execute<bool>(
        operationId: id,
        request: CommandRequest(
          kind: OperationKind.redeemAward,
          arguments: {'award': award.id.value, 'time': time, 'budget': budget},
        ),
        committedAt: (_) => calendar.assign(clock.utc, f.zone),
        action: (command) async {
          await command.postLedger([
            f.entry(
              award,
              const TimeDimension(),
              time,
              n: serial++,
              op: int.parse(id.value.split('-').last),
            ),
            if (budget > 0)
              f.entry(
                award,
                BudgetDimension(
                  (award.configuration as AwardConfiguration)
                      .budgetGrant!
                      .currency,
                ),
                budget,
                n: serial++,
                op: int.parse(id.value.split('-').last),
              ),
          ]);
          return true;
        },
      ),
    );
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('minutrove-sessions-');
    clock = SessionClock();
    await open();
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  test('Award reboot recovery consumes only the original time run and never its budget', () async {
    final item = await save(f.award());
    await grant(item, 60000, budget: 1000);
    final started = await start(item);
    clock.advance(10000);
    await reconcile(started.session);
    await store.close();
    clock.boot = 'new-boot';
    clock.monotonic = 100;
    clock.utc = clock.utc.add(const Duration(days: 30));
    await open();
    final recovered = await reconcile(started.session);
    expect(recovered.session.status, SessionStatus.completed);
    expect(recovered.session.settled.value, 60000);
    expect(recovered.economy.awards.single.time!.value, 0);
    expect(recovered.economy.awards.single.budget!.minorUnits, 1000);
    expect(recovered.economy.awards.single.isExhausted, isFalse);
    expect((await reconcile(started.session)).economy.entries, isEmpty);
    expect(
      f.success(await store.read((r) => r.projectionMismatches())),
      isEmpty,
    );
  });

  test('five active minutes retain exact earnings; paused time and repeated commands add zero', () async {
    final q = await save(configuredQuest());
    final started = await start(q);
    expect(started.session.duration.value, 900000);
    expect(started.session.deadlineUtc, f.now.add(const Duration(minutes: 15)));
    clock.advance(120123);
    final pauseId = op();
    final paused = await pause(started.session, id: pauseId);
    expect(paused.session.status, SessionStatus.paused);
    expect(paused.notificationIntent.deadlineUtc, isNull);
    clock.advance(3600000);
    final repeated = await pause(paused.session);
    expect(repeated.session.revision, paused.session.revision);
    expect(repeated.economy.entries, isEmpty);
    expect((await start(q)).session.status, SessionStatus.paused);
    expect((await reconcile(paused.session)).session.settled.value, 120123);
    final resumed = await resume(paused.session);
    expect(
      resumed.session.deadlineUtc,
      clock.utc.add(const Duration(milliseconds: 779877)),
    );
    expect(
      (await resume(resumed.session)).session.revision,
      resumed.session.revision,
    );
    clock.advance(179877);
    final ended = await end(resumed.session);
    expect(ended.session.status, SessionStatus.ended);
    expect(ended.session.settled.value, 300000);
    expect(ended.economy.wallet.balances.coins.units, 10000000);
    expect(ended.economy.wallet.balances.gems.units, 200000);
    expect(ended.economy.activeSession, isNull);
    expect(ended.session.intervals.map((x) => x.active.value), [
      120123,
      179877,
    ]);
    clock.advance(1000000);
    expect((await end(ended.session)).economy.entries, isEmpty);
    expect(
      (await reconcile(ended.session)).session.revision,
      ended.session.revision,
    );
    final replay = await pause(started.session, id: pauseId);
    expect(replay.session.status, SessionStatus.paused);
    expect(
      replay.economy.wallet.balances.coins.units,
      paused.economy.wallet.balances.coins.units,
    );
    expect(
      f.success(await repo.getSession(started.session.id))!.status,
      SessionStatus.ended,
    );
    expect(
      (await repo.resumeSession(
        operationId: op(),
        sessionId: ended.session.id,
        expectedRevision: ended.session.revision,
      ) as Failure).error,
      isA<InvalidSessionTransition>(),
    );
  });

  test('same and distinct operation IDs cannot create a second active or paused session', () async {
    final q = await save(configuredQuest());
    final other = await save(configuredQuest(id: 2));
    final id = op();
    final replies = await Future.wait(
      List.generate(24, (_) => start(q, id: id)),
    );
    expect(replies.map((r) => r.session.id).toSet().length, 1);
    final taps = await Future.wait(List.generate(12, (_) => start(q)));
    expect(taps.map((r) => r.session.id).toSet(), {replies.first.session.id});
    for (final s in [
      replies.first.session,
      (await pause(replies.first.session)).session,
    ]) {
      expect(s.occupiesSlot, isTrue);
      final conflict = await repo.startSession(
        operationId: op(),
        itemId: other.id,
        expectedItemRevision: other.revision,
        conflictChoice: SessionConflictChoice.cancel,
      );
      expect((conflict as Failure).error, isA<ActiveSessionConflict>());
    }
    final changed = await repo.startSession(
      operationId: id,
      itemId: other.id,
      expectedItemRevision: other.revision,
      conflictChoice: SessionConflictChoice.cancel,
    );
    expect((changed as Failure).error, isA<InvalidInput>());
    expect(await repo.watchActiveSession().first, isNotNull);
  });

  test(
    'competing different starts and stale transitions fail without effects',
    () async {
      final q = await save(configuredQuest());
      final other = await save(configuredQuest(id: 2));
      final results = await Future.wait([
        for (final item in [q, other])
          repo.startSession(
            operationId: op(),
            itemId: item.id,
            expectedItemRevision: item.revision,
            conflictChoice: SessionConflictChoice.cancel,
          ),
      ]);
      expect(results.whereType<Success<SessionMutation>>().length, 1);
      expect(
        (results.whereType<Failure<SessionMutation>>().single).error,
        isA<ActiveSessionConflict>(),
      );
      final s = results
          .whereType<Success<SessionMutation>>()
          .single
          .value
          .session;
      clock.advance(1000);
      await pause(s);
      final before = await dump('${dir.path}/test.db');
      final stale = await repo.endSession(
        operationId: op(),
        sessionId: s.id,
        expectedRevision: s.revision,
      );
      expect((stale as Failure).error, isA<StaleRevision>());
      expect(await dump('${dir.path}/test.db'), before);
    },
  );

  test(
    'explicit replacement settles and releases old slot atomically',
    () async {
      final q = await save(configuredQuest());
      final other = await save(configuredQuest(id: 2));
      final first = await start(q);
      clock.advance(30123);
      final second = await start(
        other,
        choice: SessionConflictChoice.endCurrentAndContinue,
      );
      expect(second.economy.activeSession!.id, second.session.id);
      expect(
        second.economy.entries
            .where((e) => e.dimension is TimeDimension)
            .single
            .delta,
        30123,
      );
      final old = f.success(await repo.getSession(first.session.id))!;
      expect(old.status, SessionStatus.ended);
      expect(old.settled.value, 30123);
      expect(
        f
            .success(await store.read((r) => r.notificationIntents()))
            .singleWhere((n) => n.sessionId == old.id)
            .deadlineUtc,
        isNull,
      );
      final paused = await pause(second.session);
      clock.advance(10000);
      await start(q, choice: SessionConflictChoice.endCurrentAndContinue);
      expect(
        f.success(await repo.getSession(paused.session.id))!.settled.value,
        0,
      );
    },
  );

  test('zero completes once, caps overrun and replays durably before reading clock', () async {
    final q = await save(configuredQuest(seconds: 1));
    final started = await start(q);
    clock.advance(5000);
    final id = op();
    final completed = await reconcile(started.session, id: id);
    expect(completed.session.status, SessionStatus.completed);
    expect(completed.session.settled.value, 1000);
    expect(
      completed.session.intervals.single.endedAt.utc,
      f.now.add(const Duration(seconds: 1)),
    );
    expect(completed.notificationIntent.deadlineUtc, isNull);
    expect(
      completed.notificationIntent.completionId,
      started.session.completionId,
    );
    final frozen = RecordCodec(f.metadata).encode(completed);
    await store.close();
    await open();
    clock.unavailable = true;
    expect(
      RecordCodec(f.metadata).encode(await reconcile(started.session, id: id)),
      frozen,
    );
    clock.unavailable = false;
    clock.advance(9000000);
    expect((await reconcile(started.session)).economy.entries, isEmpty);
    expect(await repo.watchActiveSession().first, isNull);
    final next = await start(q);
    expect(next.session.completionId, isNot(completed.session.completionId));
  });

  test(
    'pausing or ending at the deadline completes instead of ending early',
    () async {
      final q = await save(configuredQuest(seconds: 1));
      final first = await start(q);
      clock.advance(1000);
      expect(
        (await pause(first.session)).session.status,
        SessionStatus.completed,
      );
      final second = await start(q);
      clock.advance(1001);
      expect(
        (await end(second.session)).session.status,
        SessionStatus.completed,
      );
    },
  );

  test('fractional currencies carry across checkpoints, early ends, restarts and changed rates', () async {
    var q = await save(configuredQuest(seconds: 1, coins: 3601, gems: 7199));
    final first = await start(q);
    clock.advance(333);
    final checkpoint = await reconcile(first.session);
    clock.advance(167);
    await end(checkpoint.session);
    await store.close();
    await open();
    final second = await start(q);
    clock.advance(500);
    final whole = await end(second.session);
    expect(whole.economy.wallet.balances.coins.units, 1);
    expect(whole.economy.wallet.balances.gems.units, 1);
    expect(
      f
          .success(
            await store.read((r) => r.remainder(q.id, VirtualCurrency.coins)),
          )!
          .remainder
          .value,
      1000,
    );
    expect(
      f
          .success(
            await store.read((r) => r.remainder(q.id, VirtualCurrency.gems)),
          )!
          .remainder
          .value,
      3599000,
    );
    q = await save(
      configuredQuest(
        seconds: 1,
        coins: 3599,
        gems: 1,
        revision: q.revision.value,
      ),
      create: false,
    );
    final third = await start(q);
    clock.advance(1000);
    final last = await end(third.session);
    expect(last.economy.wallet.balances.coins.units, 2);
    expect(last.economy.wallet.balances.gems.units, 2);
  });

  test('current configuration edits leave active duration, rates, revision and zone frozen', () async {
    var q = await save(configuredQuest(seconds: 10));
    final s = (await start(q)).session;
    q = await save(
      configuredQuest(
        seconds: 20,
        coins: 3600000,
        gems: 0,
        revision: q.revision.value,
      ),
      create: false,
    );
    final invalid = await repo.startSession(
      operationId: op(),
      itemId: q.id,
      expectedItemRevision: Revision(1),
      conflictChoice: SessionConflictChoice.cancel,
    );
    expect((invalid as Failure).error, isA<StaleRevision>());
    clock.advance(5000);
    final settled = await end(s);
    expect(settled.session.itemSnapshot.revision, Revision(1));
    expect(settled.session.duration.value, 10000);
    expect(settled.economy.wallet.balances.coins.units, 166666);
    expect(
      settled.economy.entries.every((e) => e.itemRevision == Revision(1)),
      isTrue,
    );
    expect((await start(q)).session.duration.value, 20000);
  });

  test('timed Award uses pooled time, pause costs zero, purchase does not extend run or consume budget', () async {
    final a = await save(f.award());
    await grant(a, 45000, budget: 1000);
    final started = await start(a);
    expect(started.session.duration.value, 45000);
    clock.advance(12001);
    final paused = await pause(started.session);
    expect(paused.economy.awards.single.time!.value, 32999);
    clock.advance(3600000);
    await grant(a, 30000);
    final running = await resume(paused.session);
    clock.advance(2999);
    final ended = await end(running.session);
    expect(ended.economy.awards.single.time!.value, 60000);
    expect(ended.economy.awards.single.budget!.minorUnits, 1000);
    final next = await start(a);
    clock.advance(90000);
    final completed = await reconcile(next.session);
    expect(completed.session.settled.value, 60000);
    expect(completed.economy.awards.single.time!.value, 0);
    expect(completed.economy.awards.single.isExhausted, isFalse);
    expect(
      (await repo.startSession(
        operationId: op(),
        itemId: a.id,
        expectedItemRevision: a.revision,
        conflictChoice: SessionConflictChoice.cancel,
      ) as Failure).error,
      isA<AllowanceExceeded>(),
    );
  });

  test('earned currency funds real pack purchases while a timed session retains its countdown', () async {
    final q = await save(configuredQuest());
    final a = await save(f.award());
    final earning = await start(q);
    clock.advance(300000);
    await end(earning.session);
    final purchases = SqliteAwardRedemptionRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
    f.success(
      await purchases.redeemAward(
        operationId: op(),
        awardId: a.id,
        expectedRevision: a.revision,
        quantity: PurchaseQuantity(2),
      ),
    );
    final spending = await start(a);
    expect(spending.session.duration.value, 120000);
    clock.advance(12345);
    f.success(
      await purchases.redeemAward(
        operationId: op(),
        awardId: a.id,
        expectedRevision: a.revision,
        quantity: PurchaseQuantity(3),
      ),
    );
    final result = await end(spending.session);
    expect(result.session.duration.value, 120000);
    expect(result.economy.awards.single.time!.value, 287655);
    expect(result.economy.awards.single.budget!.minorUnits, 5000);
    expect(result.economy.wallet.balances.coins.units, 9999900);
    expect(
      f.success(await store.read((r) => r.projectionMismatches())),
      isEmpty,
    );
  });

  test('archived Quest cannot start; archived purchased Award remains usable; invalid replacement keeps old session', () async {
    final q = await save(configuredQuest());
    final archived = await save(configuredQuest(id: 3, archived: true));
    final a = await save(f.award());
    final started = await start(q);
    clock.advance(1000);
    final before = await dump('${dir.path}/test.db');
    for (final item in [archived, a]) {
      expect(
        await repo.startSession(
          operationId: op(),
          itemId: item.id,
          expectedItemRevision: item.revision,
          conflictChoice: SessionConflictChoice.endCurrentAndContinue,
        ),
        isA<Failure<SessionMutation>>(),
      );
      expect(await dump('${dir.path}/test.db'), before);
    }
    await end(started.session);
    await grant(a, 10000);
    final saved = f.success(
      await SqliteItemRepository(
        store: store,
        clock: clock,
        calendar: calendar,
      ).archiveItem(
        operationId: op(),
        itemId: a.id,
        expectedRevision: a.revision,
      ),
    );
    expect((await start(saved)).session.duration.value, 10000);
  });

  test('reopen catches elapsed running time but never includes persisted paused time', () async {
    final q = await save(configuredQuest());
    final s = (await start(q)).session;
    await store.close();
    clock.advance(5000);
    await open();
    final current = await reconcile(s);
    expect(current.session.settled.value, 5000);
    final paused = await pause(current.session);
    await store.close();
    clock.advance(1000000);
    await open();
    expect((await reconcile(paused.session)).session.settled.value, 5000);
    final resumed = await resume(paused.session);
    clock.advance(1000);
    expect((await end(resumed.session)).session.settled.value, 6000);
  });

  test('same-boot wall changes cannot change earnings; midnight assignments split active time', () async {
    clock.utc = DateTime.utc(2026, 1, 15, 23, 59, 59);
    final q = await save(configuredQuest());
    final s = (await start(q)).session;
    clock.advance(2000);
    final updated = await reconcile(s);
    expect(updated.session.intervals.map((i) => i.active.value), [1000, 1000]);
    expect(updated.session.intervals.map((i) => i.assignment.day), [
      DayKey(2026, 1, 15),
      DayKey(2026, 1, 16),
    ]);
    clock.advance(1000);
    clock.utc = clock.utc.subtract(const Duration(hours: 5));
    final ended = await end(updated.session);
    expect(ended.session.settled.value, 3000);
    expect(ended.economy.wallet.balances.coins.units, 100000);
    expect(
      ended.session.intervals.fold(0, (int t, i) => t + i.active.value),
      3000,
    );
  });

  test(
    'wallet overflow rolls back session, intervals, remainder and operation',
    () async {
      final q = await save(
        configuredQuest(coins: maxStoredInteger, gems: 0, seconds: 7200),
      );
      final s = (await start(q)).session;
      clock.advance(7200000);
      final before = await dump('${dir.path}/test.db');
      expect(
        (await repo.endSession(
          operationId: op(),
          sessionId: s.id,
          expectedRevision: s.revision,
        ) as Failure).error,
        isA<NumericOverflow>(),
      );
      expect(await dump('${dir.path}/test.db'), before);
    },
  );

  test('replacement failure at every write and COMMIT reopens to all or nothing, then retries exactly once', () async {
    await store.close();
    final factory = FaultFactory();
    await open(factory: factory);
    final q = await save(configuredQuest());
    final other = await save(configuredQuest(id: 2));
    await start(q);
    clock.advance(12345);
    final id = op();
    await store.close();
    final path = '${dir.path}/test.db';
    final baseline = await File(path).readAsBytes();
    final original = await dump(path);
    await open(factory: factory);
    factory.arm();
    final result = await start(
      other,
      id: id,
      choice: SessionConflictChoice.endCurrentAndContinue,
    );
    final writes = factory.writes;
    factory.disarm();
    await store.close();
    final full = await dump(path);
    expect(writes, greaterThan(15));
    stdout.writeln(
      'Session replacement acceptance: $writes SQL writes and both COMMIT boundaries',
    );
    for (final boundary in [...List.generate(writes, (i) => i + 1), -1, -2]) {
      await File(path).writeAsBytes(baseline, flush: true);
      await open(factory: factory);
      factory.arm(failure: boundary);
      final failed = await repo.startSession(
        operationId: id,
        itemId: other.id,
        expectedItemRevision: other.revision,
        conflictChoice: SessionConflictChoice.endCurrentAndContinue,
      );
      expect(
        (failed as Failure).error,
        isA<StorageUnavailable>(),
        reason: '$boundary',
      );
      factory.disarm();
      await store.close();
      expect(
        await dump(path),
        boundary == -2 ? full : original,
        reason: '$boundary',
      );
      await open(factory: factory);
      final retried = await start(
        other,
        id: id,
        choice: SessionConflictChoice.endCurrentAndContinue,
      );
      expect(
        RecordCodec(f.metadata).encode(retried),
        RecordCodec(f.metadata).encode(result),
      );
      await store.close();
      expect(await dump(path), full, reason: 'retry $boundary');
    }
    await open();
  });
}
