import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/session_fixtures.dart';
import 'fault_database.dart';
import 'support.dart' as f;

void main() {
  sqfliteFfiInit();
  final calendar = IanaReportingCalendar();
  final codec = RecordCodec(f.metadata);
  late Directory dir;
  late SqliteStore store;
  late SqliteSessionRepository sessions;
  late SqliteItemRepository items;
  late SqliteSettingsRepository settings;
  late SessionClock clock;
  var serial = 10000;
  OperationId op() => OperationId(f.uuid(serial++));
  String getPath() => '${dir.path}/daily.db';

  Future<void> open({
    DatabaseFactory? factory,
    String initialZone = 'Etc/UTC',
  }) async {
    store = f.success(
      await SqliteStore.open(
        path: getPath(),
        factory: factory ?? databaseFactoryFfi,
        currencies: f.metadata,
        initialSettings: AppSettings(
          revision: Revision(1),
          reportingZone: ReportingZone(initialZone),
        ),
      ),
    );
    sessions = SqliteSessionRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
    items = SqliteItemRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
    settings = SqliteSettingsRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
  }

  Future<Item> saveGoal({
    Item? previous,
    int id = 1,
    int? targetSeconds = 60,
    int bonusCoins = 1000000,
    int bonusGems = 2000000,
    int durationSeconds = 259200,
    int rate = 3600000,
  }) async {
    final base = previous ?? configuredQuest(id: id);
    final item = Item(
      id: base.id,
      revision: base.revision,
      name: base.name,
      iconKey: base.iconKey,
      colorArgb: base.colorArgb,
      groupId: base.groupId,
      order: base.order,
      archived: base.archived,
      configuration: QuestConfiguration(
        duration: Milliseconds.seconds(durationSeconds),
        ratesPerHour: f.amounts(rate),
        dailyGoal: targetSeconds == null
            ? null
            : DailyGoal(
                target: Milliseconds.seconds(targetSeconds),
                bonus: f.amounts(bonusCoins, bonusGems),
              ),
      ),
    );
    return f.success(
      await items.saveItem(
        operationId: op(),
        item: item,
        expectedRevision: previous?.revision,
      ),
    );
  }

  Future<Session> start(Item item) async => f
      .success(
        await sessions.startSession(
          operationId: op(),
          itemId: item.id,
          expectedItemRevision: item.revision,
          conflictChoice: SessionConflictChoice.cancel,
        ),
      )
      .session;
  Future<SessionMutation> settle(
    Session session, {
    OperationId? id,
    bool end = false,
  }) async => f.success(
    end
        ? await sessions.endSession(
            operationId: id ?? op(),
            sessionId: session.id,
            expectedRevision: session.revision,
          )
        : await sessions.reconcileSession(
            operationId: id ?? op(),
            sessionId: session.id,
          ),
  );
  Future<AppSettings> zone(
    String name, {
    OperationId? id,
    Revision? expected,
  }) async => f.success(
    await settings.saveSettings(
      operationId: id ?? op(),
      expectedRevision:
          expected ?? f.success(await settings.getSettings()).revision,
      reportingZone: ReportingZone(name),
    ),
  );
  Future<List<DailyAchievement>> achievements(Item item) async =>
      f.success(await store.read((r) => r.achievements(questId: item.id)));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('minutrove-daily-goals-');
    clock = SessionClock();
    await open();
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  test('cumulative sessions pay once, exclude pause, keep ordinary earnings and replay after reopening', () async {
    final quest = await saveGoal();
    var s = await start(quest);
    clock.advance(30000);
    var result = f.success(
      await sessions.pauseSession(
        operationId: op(),
        sessionId: s.id,
        expectedRevision: s.revision,
      ),
    );
    expect(result.economy.achievements, isEmpty);
    clock.advance(3600000);
    s = f
        .success(
          await sessions.resumeSession(
            operationId: op(),
            sessionId: s.id,
            expectedRevision: result.session.revision,
          ),
        )
        .session;
    clock.advance(29999);
    result = await settle(s);
    expect(result.economy.achievements, isEmpty);
    clock.advance(1);
    final creditId = op();
    final credit = await settle(result.session, id: creditId);
    expect(credit.economy.achievements.single.day, DayKey(2026, 1, 15));
    expect(credit.economy.wallet.balances.coins.units, 1060000);
    expect(credit.economy.wallet.balances.gems.units, 2000000);
    clock.advance(20000);
    result = await settle(credit.session, end: true);
    expect(result.economy.wallet.balances.coins.units, 1080000);
    s = await start(quest);
    clock.advance(60000);
    result = await settle(s, end: true);
    expect(result.economy.wallet.balances.coins.units, 1140000);
    expect(await achievements(quest), hasLength(1));
    await store.close();
    // Initial device zone is only used on first creation, never on reopening.
    await open(initialZone: 'Asia/Tokyo');
    expect(
      f.success(await settings.getSettings()).reportingZone.ianaName,
      'Etc/UTC',
    );
    clock.unavailable = true;
    final replays = await Future.wait(
      List.generate(24, (_) => settle(credit.session, id: creditId)),
    );
    expect(replays.map((r) => codec.encode(r)).toSet(), {codec.encode(credit)});
    clock.unavailable = false;
    final callbacks = await Future.wait(
      List.generate(24, (_) => settle(result.session)),
    );
    expect(
      callbacks.every(
        (r) => r.economy.entries.isEmpty && r.economy.achievements.isEmpty,
      ),
      isTrue,
    );
    expect(await achievements(quest), hasLength(1));
    expect(
      f.success(await store.read((r) => r.projectionMismatches())),
      isEmpty,
    );
  });

  test('midnight settles both dates atomically, including a goal met at the boundary', () async {
    clock.utc = DateTime.utc(2026, 1, 15, 23, 59);
    final quest = await saveGoal();
    final s = await start(quest);
    clock.advance(120000);
    final result = await settle(s, end: true);
    expect(result.session.intervals.map((i) => i.active.value), [60000, 60000]);
    expect(result.economy.achievements.map((a) => a.day), [
      DayKey(2026, 1, 15),
      DayKey(2026, 1, 16),
    ]);
    expect(result.economy.wallet.balances.coins.units, 2120000);
    expect(
      result.economy.achievements.first.awardedAt.utc,
      DateTime.utc(2026, 1, 15, 23, 59, 59, 999),
    );
    expect(
      result.economy.achievements.last.awardedAt.utc,
      DateTime.utc(2026, 1, 16, 0, 1),
    );
    for (final day in [DayKey(2026, 1, 15), DayKey(2026, 1, 16)]) {
      expect(
        f.success(await store.read((r) => r.questActiveOn(quest.id, day))),
        BigInt.from(60000),
      );
    }
  });

  for (final sample in [
    ('2026-03-08T07:59:30Z', 23, -28800, -25200),
    ('2026-11-01T06:59:30Z', 25, -25200, -28800),
  ]) {
    test(
      'Los Angeles ${sample.$2}-hour DST day preserves elapsed time and one reward per date',
      () async {
        await zone('America/Los_Angeles');
        clock.utc = DateTime.parse(sample.$1);
        final quest = await saveGoal(targetSeconds: 30);
        final s = await start(quest);
        clock.advance(sample.$2 * 3600000 + 60000);
        final result = await settle(s, end: true);
        expect(result.session.intervals.map((i) => i.active.value), [
          30000,
          sample.$2 * 3600000,
          30000,
        ]);
        expect(
          result.session.intervals.first.assignment.offsetSeconds,
          sample.$3,
        );
        expect(
          result.session.intervals.last.assignment.offsetSeconds,
          sample.$4,
        );
        expect(result.economy.achievements, hasLength(3));
        expect(
          result.economy.achievements.map((a) => a.day).toSet(),
          hasLength(3),
        );
        expect(
          result.economy.wallet.balances.coins.units,
          3000000 + sample.$2 * 3600000 + 60000,
        );
      },
    );
  }

  test('travel does not change the zone; explicit edits affect new sessions and operations only', () async {
    await zone('America/Los_Angeles');
    clock.utc = DateTime.utc(2026, 1, 16, 7, 59, 30);
    final quest = await saveGoal(targetSeconds: 30);
    var s = await start(quest);
    clock.advance(30000);
    var result = f.success(
      await sessions.pauseSession(
        operationId: op(),
        sessionId: s.id,
        expectedRevision: s.revision,
      ),
    );
    final frozen = codec.encode(result.session);
    await zone('Asia/Tokyo');
    expect(codec.encode(f.success(await sessions.getSession(s.id))!), frozen);
    s = f
        .success(
          await sessions.resumeSession(
            operationId: op(),
            sessionId: s.id,
            expectedRevision: result.session.revision,
          ),
        )
        .session;
    clock.advance(30000);
    result = await settle(s, end: true);
    expect(result.session.zone.ianaName, 'America/Los_Angeles');
    expect(result.economy.achievements.single.day, DayKey(2026, 1, 16));
    final history = f
        .success(await store.read((r) => r.ledger(itemId: quest.id)))
        .map(codec.encode)
        .toList();
    final newSession = await start(quest);
    expect(newSession.zone.ianaName, 'Asia/Tokyo');
    clock.advance(30000);
    final newResult = await settle(newSession, end: true);
    expect(
      newResult.economy.achievements,
      isEmpty,
    ); // January 16 was already paid in LA.
    expect(await achievements(quest), hasLength(2));
    expect(newResult.economy.wallet.balances.coins.units, 2090000);
    final all = f
        .success(await store.read((r) => r.ledger(itemId: quest.id)))
        .map(codec.encode)
        .toList();
    expect(all, containsAll(history));
    await store.close();
    await open(initialZone: 'Pacific/Auckland');
    expect(
      f.success(await settings.getSettings()).reportingZone.ianaName,
      'Asia/Tokyo',
    );
  });

  test('goal edits use today before activity, tomorrow after unsettled activity, and each day in one session', () async {
    clock.utc = DateTime.utc(2026, 1, 15, 23, 58);
    var quest = await saveGoal(targetSeconds: 120);
    quest = await saveGoal(previous: quest, targetSeconds: 60); // applies today
    final s = await start(quest);
    clock.advance(30000); // no checkpoint, but activity already exists
    quest = await saveGoal(
      previous: quest,
      targetSeconds: 30,
      bonusCoins: 3000000,
      bonusGems: 0,
      rate: 7200000,
    );
    var revisions = f.success(await store.read((r) => r.goals(quest.id)));
    expect(revisions.last.effectiveFrom, DayKey(2026, 1, 16));
    clock.advance(120000);
    final result = await settle(s, end: true);
    expect(result.economy.achievements.map((a) => a.goalRevision.value), [
      2,
      3,
    ]);
    expect(result.economy.achievements.map((a) => a.bonus.coins.units), [
      1000000,
      3000000,
    ]);
    // The running session kept its original rate despite tomorrow's new bonus.
    expect(result.economy.wallet.balances.coins.units, 4150000);
    quest = await saveGoal(
      previous: quest,
      targetSeconds: 10,
      bonusCoins: 5000000,
    );
    revisions = f.success(await store.read((r) => r.goals(quest.id)));
    expect(revisions.last.effectiveFrom, DayKey(2026, 1, 17));
    final later = await start(quest);
    clock.advance(60000);
    expect((await settle(later, end: true)).economy.achievements, isEmpty);
  });

  test('disable and re-enable edits cannot repay a date; zero bonus still records completion', () async {
    var quest = await saveGoal(targetSeconds: 1, bonusCoins: 0, bonusGems: 0);
    var s = await start(quest);
    clock.advance(1000);
    final initial = await settle(s, end: true);
    expect(initial.economy.achievements.single.bonus.coins.units, 0);
    expect(initial.economy.wallet.balances.coins.units, 1000);
    quest = await saveGoal(previous: quest, targetSeconds: null);
    s = await start(quest);
    clock.advance(1000);
    expect((await settle(s, end: true)).economy.achievements, isEmpty);
    clock.advance(const Duration(days: 1).inMilliseconds);
    s = await start(quest);
    clock.advance(1000);
    expect((await settle(s, end: true)).economy.achievements, isEmpty);
    quest = await saveGoal(previous: quest, targetSeconds: 1);
    expect(
      f.success(await store.read((r) => r.goals(quest.id))).last.effectiveFrom,
      DayKey(2026, 1, 17),
    );
    clock.advance(const Duration(days: 1).inMilliseconds);
    s = await start(quest);
    clock.advance(1000);
    expect(
      (await settle(s, end: true)).economy.achievements.single.day,
      DayKey(2026, 1, 17),
    );
  });

  test('monotonic activity defers an edit after wall-clock reversal', () async {
    var quest = await saveGoal();
    final s = await start(quest);
    clock.advance(30000);
    clock.utc = f.now.subtract(const Duration(minutes: 1));
    quest = await saveGoal(
      previous: quest,
      targetSeconds: 1,
      bonusCoins: 9000000,
    );
    expect(
      f.success(await store.read((r) => r.goals(quest.id))).last.effectiveFrom,
      DayKey(2026, 1, 16),
    );
    clock.advance(30000);
    final result = await settle(s, end: true);
    expect(result.economy.achievements.single.bonus.coins.units, 1000000);
    expect(result.economy.wallet.balances.coins.units, 1060000);
  });

  test('settings enforce revision, IANA validation and durable replay without touching history', () async {
    final id = op();
    final saved = await zone('Pacific/Auckland', id: id, expected: Revision(1));
    final baseline = await dump(getPath());
    for (final request in [
      (op(), Revision(1), 'Asia/Tokyo', isA<StaleRevision>()),
      (op(), saved.revision, 'UTC+9', isA<InvalidInput>()),
      (id, Revision(1), 'Asia/Tokyo', isA<InvalidInput>()),
    ]) {
      final result = await settings.saveSettings(
        operationId: request.$1,
        expectedRevision: request.$2,
        reportingZone: ReportingZone(request.$3),
      );
      expect((result as Failure).error, request.$4);
      expect(await dump(getPath()), baseline);
    }
    await zone('America/New_York');
    await store.close();
    await open();
    clock.unavailable = true;
    final replay = await zone(
      'Pacific/Auckland',
      id: id,
      expected: Revision(1),
    );
    expect(replay.revision, saved.revision);
    expect(
      f.success(await settings.getSettings()).reportingZone.ianaName,
      'America/New_York',
    );
  });

  test(
    'bonus overflow rolls back all progress, achievement and ordinary earnings',
    () async {
      final quest = await saveGoal(
        targetSeconds: 1,
        bonusCoins: maxStoredInteger,
        bonusGems: 0,
      );
      final s = await start(quest);
      clock.advance(1000);
      final before = await dump(getPath());
      final result = await sessions.reconcileSession(
        operationId: op(),
        sessionId: s.id,
      );
      expect((result as Failure).error, isA<NumericOverflow>());
      expect(await dump(getPath()), before);
    },
  );

  test('every two-day bonus write and both COMMIT failures recover atomically and retry once', () async {
    clock.utc = DateTime.utc(2026, 1, 15, 23, 59);
    final quest = await saveGoal();
    final s = await start(quest);
    clock.advance(120000);
    await store.close();
    final baseline = await File(getPath()).readAsBytes();
    final original = await dump(getPath());
    final factory = FaultFactory();
    await open(factory: factory);
    final id = op();
    factory.arm();
    final complete = await settle(s, id: id, end: true);
    final writes = factory.writes;
    expect(complete.economy.achievements, hasLength(2));
    expect(writes, greaterThan(15));
    factory.disarm();
    await store.close();
    final full = await dump(getPath());
    stdout.writeln(
      'Two-day daily-goal acceptance: $writes SQL writes and both COMMIT boundaries',
    );
    for (final boundary in [...List.generate(writes, (i) => i + 1), -1, -2]) {
      await File(getPath()).writeAsBytes(baseline, flush: true);
      await open(factory: factory);
      factory.arm(failure: boundary);
      final result = await sessions.endSession(
        operationId: id,
        sessionId: s.id,
        expectedRevision: s.revision,
      );
      expect(
        (result as Failure).error,
        isA<StorageUnavailable>(),
        reason: '$boundary',
      );
      factory.disarm();
      await store.close();
      expect(
        await dump(getPath()),
        boundary == -2 ? full : original,
        reason: '$boundary',
      );
      await open(factory: factory);
      expect(
        codec.encode(await settle(s, id: id, end: true)),
        codec.encode(complete),
      );
      await store.close();
      expect(await dump(getPath()), full, reason: 'retry $boundary');
    }
    await open();
  });
}
