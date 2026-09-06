import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/session_fixtures.dart';
import 'support.dart' as f;

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqliteStore store;
  late SqliteStatsRepository stats;
  late SqliteItemRepository items;
  late SqliteSessionRepository sessions;
  late SessionClock clock;
  final calendar = IanaReportingCalendar();
  var serial = 10000;
  OperationId op() => OperationId(f.uuid(serial++));
  String getPath() => '${dir.path}/stats.db';

  Future<void> open() async {
    store = f.success(
      await SqliteStore.open(
        path: getPath(),
        factory: databaseFactoryFfi,
        currencies: f.metadata,
        initialSettings: f.settings,
      ),
    );
    stats = SqliteStatsRepository(store: store);
    items = SqliteItemRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
    sessions = SqliteSessionRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
  }

  Future<void> setZone(String name) async {
    final repo = SqliteSettingsRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
    final old = f.success(await repo.getSettings());
    f.success(
      await repo.saveSettings(
        operationId: op(),
        expectedRevision: old.revision,
        reportingZone: ReportingZone(name),
      ),
    );
  }

  Future<Item> save(Item item) async => f.success(
    await items.saveItem(operationId: op(), item: item, expectedRevision: null),
  );

  Future<void> run(Item item, int milliseconds) async {
    var session = f
        .success(
          await sessions.startSession(
            operationId: op(),
            itemId: item.id,
            expectedItemRevision: item.revision,
            conflictChoice: SessionConflictChoice.cancel,
          ),
        )
        .session;
    clock.advance(milliseconds);
    f.success(
      await sessions.endSession(
        operationId: op(),
        sessionId: session.id,
        expectedRevision: session.revision,
      ),
    );
  }

  Future<List<StatsBucket>> query(
    StatsMetric metric, {
    StatsPeriod period = StatsPeriod.daily,
    DayKey? day,
    StatsCategory category = StatsCategory.all,
    ItemId? itemId,
    BudgetCurrency? currency,
  }) async => f.success(
    await stats.query(
      StatsQuery(
        period: period,
        anchor: day ?? DayKey(2026, 1, 15),
        category: category,
        metric: metric,
        itemId: itemId,
        budgetCurrency: currency,
      ),
    ),
  );

  int total(List<StatsBucket> buckets) =>
      buckets.fold(0, (sum, b) => sum + b.value);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('minutrove-stats-');
    clock = SessionClock();
    await open();
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  test(
    'zero fills hours, Monday weeks, leap months and calendar years',
    () async {
      for (final (period, day, count, start, end) in [
        (
          StatsPeriod.daily,
          DayKey(2024, 2, 29),
          24,
          DateTime.utc(2024, 2, 29),
          DateTime.utc(2024, 3),
        ),
        (
          StatsPeriod.weekly,
          DayKey(2023, 1, 1),
          7,
          DateTime.utc(2022, 12, 26),
          DateTime.utc(2023, 1, 2),
        ),
        (
          StatsPeriod.monthly,
          DayKey(2024, 2, 29),
          29,
          DateTime.utc(2024, 2),
          DateTime.utc(2024, 3),
        ),
        (
          StatsPeriod.monthly,
          DayKey(2025, 2, 28),
          28,
          DateTime.utc(2025, 2),
          DateTime.utc(2025, 3),
        ),
        (
          StatsPeriod.yearly,
          DayKey(9999, 12, 31),
          12,
          DateTime.utc(9999),
          DateTime.utc(10000),
        ),
      ]) {
        final buckets = await query(
          StatsMetric.questTime,
          period: period,
          day: day,
        );
        expect(buckets.length, count);
        expect(buckets.first.start, start);
        expect(buckets.last.end, end);
        expect(total(buckets), 0);
        for (var i = 1; i < buckets.length; i++) {
          expect(buckets[i].start, buckets[i - 1].end);
        }
      }
    },
  );

  test('actual sessions split hourly and midnight, include bonus once and retain archived history', () async {
    clock.utc = DateTime.utc(2024, 2, 28, 23, 30);
    final base = configuredQuest(seconds: 7200, coins: 3600000, gems: 7200000);
    final item = await save(
      Item(
        id: base.id,
        revision: base.revision,
        name: base.name,
        iconKey: base.iconKey,
        colorArgb: base.colorArgb,
        groupId: null,
        order: 0,
        archived: false,
        configuration: QuestConfiguration(
          duration: Milliseconds.seconds(7200),
          ratesPerHour: f.amounts(3600000, 7200000),
          dailyGoal: DailyGoal(
            target: Milliseconds.seconds(1800),
            bonus: f.amounts(100, 200),
          ),
        ),
      ),
    );
    await run(item, 5400000);
    final before = await query(StatsMetric.questTime, day: DayKey(2024, 2, 28));
    final after = await query(StatsMetric.questTime, day: DayKey(2024, 2, 29));
    expect(before[23].value, 1800000);
    expect(after[0].value, 3600000);
    expect(total(before) + total(after), 5400000);
    final goals = await query(
      StatsMetric.dailyGoalCompletion,
      period: StatsPeriod.monthly,
      day: DayKey(2024, 2, 29),
    );
    expect(goals[27].value, 1);
    expect(goals[28].value, 1);
    expect(
      total(
        await query(StatsMetric.dailyGoalCompletion, day: DayKey(2024, 2, 28)),
      ),
      1,
    );
    final ledger = f.success(await store.read((r) => r.ledger()));
    for (final (metric, currency) in [
      (StatsMetric.coinsEarned, VirtualCurrency.coins),
      (StatsMetric.gemsEarned, VirtualCurrency.gems),
    ]) {
      final expected = ledger
          .where(
            (e) =>
                e.dimension is VirtualCurrencyDimension &&
                (e.dimension as VirtualCurrencyDimension).currency == currency,
          )
          .fold(0, (sum, e) => sum + e.delta);
      for (final period in [
        StatsPeriod.weekly,
        StatsPeriod.monthly,
        StatsPeriod.yearly,
      ]) {
        expect(
          total(await query(metric, period: period, day: DayKey(2024, 2, 29))),
          expected,
        );
      }
    }
    f.success(
      await items.archiveItem(
        operationId: op(),
        itemId: item.id,
        expectedRevision: item.revision,
      ),
    );
    expect(
      total(
        await query(
          StatsMetric.questTime,
          period: StatsPeriod.yearly,
          day: DayKey(2024, 2, 29),
          category: StatsCategory.item,
          itemId: item.id,
        ),
      ),
      5400000,
    );
    await setZone('Asia/Tokyo');
    await store.close();
    await open();
    expect(
      (await query(StatsMetric.questTime, day: DayKey(2024, 2, 28)))[23].value,
      1800000,
    );
  });

  for (final (name, start, hours, day, expected) in [
    (
      'spring forward',
      DateTime.utc(2026, 3, 8, 8),
      4,
      DayKey(2026, 3, 8),
      <int, int>{0: 1, 1: 1, 2: 0, 3: 1, 4: 1},
    ),
    (
      'fall back',
      DateTime.utc(2026, 11, 1, 7),
      4,
      DayKey(2026, 11, 1),
      <int, int>{0: 1, 1: 2, 2: 1},
    ),
  ]) {
    test(
      '$name uses actual duration while keeping 24 civil hour labels',
      () async {
        await setZone('America/Los_Angeles');
        clock.utc = start;
        final item = await save(configuredQuest(seconds: 86400));
        await run(item, hours * 3600000);
        final buckets = await query(StatsMetric.questTime, day: day);
        expect(buckets.length, 24);
        for (final e in expected.entries) {
          expect(buckets[e.key].value, e.value * 3600000);
        }
        expect(total(buckets), hours * 3600000);
        expect(
          total(
            await query(
              StatsMetric.questTime,
              period: StatsPeriod.monthly,
              day: day,
            ),
          ),
          total(buckets),
        );
      },
    );
  }

  test('half-hour DST and pause allocate only committed active time', () async {
    await setZone('Australia/Lord_Howe');
    clock.utc = DateTime.utc(
      2026,
      10,
      3,
      15,
    ); // 01:30 -> 02:30 jump, then 03:00.
    final item = await save(configuredQuest(seconds: 86400));
    await run(item, 3600000);
    final buckets = await query(
      StatsMetric.questTime,
      day: DayKey(2026, 10, 4),
    );
    expect(buckets[1].value, 1800000);
    expect(buckets[2].value, 1800000);
    final s = f
        .success(
          await sessions.startSession(
            operationId: op(),
            itemId: item.id,
            expectedItemRevision: item.revision,
            conflictChoice: SessionConflictChoice.cancel,
          ),
        )
        .session;
    clock.advance(60000);
    final paused = f
        .success(
          await sessions.pauseSession(
            operationId: op(),
            sessionId: s.id,
            expectedRevision: s.revision,
          ),
        )
        .session;
    clock.advance(3600000);
    expect(
      total(await query(StatsMetric.questTime, day: DayKey(2026, 10, 4))),
      3660000,
    );
    f.success(
      await sessions.endSession(
        operationId: op(),
        sessionId: paused.id,
        expectedRevision: paused.revision,
      ),
    );
    expect(
      total(await query(StatsMetric.questTime, day: DayKey(2026, 10, 4))),
      3660000,
    );
  });

  test('purchases, usage, each budget currency, and individual compatibility stay separate', () async {
    final quest = await save(
      configuredQuest(seconds: 7200, coins: 360000000, gems: 360000000),
    );
    await run(quest, 3600000);
    final usd = BudgetCurrency.fromMetadata('USD', f.metadata);
    final jpy = BudgetCurrency.fromMetadata('JPY', f.metadata);
    final awards = <Item>[];
    for (final (id, currency) in [(2, usd), (3, jpy)]) {
      final base = f.award(n: id);
      awards.add(
        await save(
          Item(
            id: base.id,
            revision: base.revision,
            name: base.name,
            iconKey: base.iconKey,
            colorArgb: base.colorArgb,
            groupId: null,
            order: id,
            archived: false,
            configuration: AwardConfiguration(
              packName: 'Pack',
              price: f.amounts(20, 30),
              timeGrant: Milliseconds.seconds(7200),
              budgetGrant: BudgetAmount(currency, 3500),
            ),
          ),
        ),
      );
    }
    final economy = SqliteEconomyRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
    for (final award in awards) {
      final purchased = f.success(
        await economy.redeemAward(
          operationId: op(),
          awardId: award.id,
          expectedRevision: award.revision,
          quantity: PurchaseQuantity(1),
        ),
      );
      final balance = purchased.awards.singleWhere(
        (b) => b.awardId == award.id,
      );
      f.success(
        await economy.recordExpense(
          operationId: op(),
          awardId: award.id,
          expectedBalanceRevision: balance.revision,
          expense: BudgetAmount(balance.budget!.currency, 1250),
          conflictChoice: SessionConflictChoice.cancel,
        ),
      );
    }
    clock.utc = DateTime.utc(2026, 1, 15, 14, 30);
    await run(awards.first, 3600000);
    expect(total(await query(StatsMetric.questTime)), 3600000);
    final used = await query(StatsMetric.awardTime);
    expect(used[14].value, 1800000);
    expect(used[15].value, 1800000);
    expect(total(used), 3600000); // excludes the 4 hours granted by purchases
    expect(
      total(
        await query(StatsMetric.coinsSpent, category: StatsCategory.currencies),
      ),
      40,
    );
    expect(
      total(await query(StatsMetric.gemsSpent, category: StatsCategory.awards)),
      60,
    );
    for (final currency in [usd, jpy]) {
      expect(
        total(await query(StatsMetric.budgetSpent, currency: currency)),
        1250,
      );
    }
    expect(
      total(
        await query(
          StatsMetric.coinsSpent,
          category: StatsCategory.item,
          itemId: awards.first.id,
        ),
      ),
      20,
    );
    for (final (item, metric, currency) in [
      (quest, StatsMetric.awardTime, null),
      (awards.first, StatsMetric.questTime, null),
      (awards.first, StatsMetric.budgetSpent, jpy),
    ]) {
      final result = await stats.query(
        StatsQuery(
          period: StatsPeriod.daily,
          anchor: DayKey(2026, 1, 15),
          category: StatsCategory.item,
          itemId: item.id,
          metric: metric,
          budgetCurrency: currency,
        ),
      );
      expect((result as Failure).error, isA<InvalidInput>());
    }
    final missing = await stats.query(
      StatsQuery(
        period: StatsPeriod.daily,
        anchor: DayKey(2026, 1, 15),
        category: StatsCategory.item,
        itemId: ItemId(f.uuid(999)),
        metric: StatsMetric.questTime,
      ),
    );
    expect((missing as Failure).error, isA<NotFound>());
    await store.close();
    expect(
      (await stats.query(
        StatsQuery(
          period: StatsPeriod.daily,
          anchor: DayKey(2026, 1, 15),
          category: StatsCategory.all,
          metric: StatsMetric.questTime,
        ),
      ) as Failure).error,
      isA<StorageUnavailable>(),
    );
  });

  test('multi-year history aggregates exact integers with bounded daily pages', () async {
    f.success(await store.write(f.seed));
    await store.close();
    final db = await databaseFactoryFfi.openDatabase(getPath());
    await db.transaction((tx) async {
      final batch = tx.batch();
      for (var n = 0; n < 20000; n++) {
        final day = DateTime.utc(2000).add(Duration(days: n % 10000));
        batch.rawInsert(
          '''INSERT INTO ledger_entries
          (id,operation_id,item_id,item_revision,dimension,delta,assigned_utc,assigned_day,assigned_zone,assigned_offset)
          VALUES(?,?,?,?,?,?,?,?,?,?)''',
          [
            f.uuid(100000 + n),
            f.uuid(5),
            f.quest().id.value,
            1,
            'time',
            60000,
            day.millisecondsSinceEpoch,
            '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
            'Etc/UTC',
            0,
          ],
        );
      }
      // More than one page on the same date; all belong to hour zero.
      for (var n = 0; n < 1100; n++) {
        batch.rawInsert(
          '''INSERT INTO ledger_entries
          (id,operation_id,item_id,item_revision,dimension,delta,assigned_utc,assigned_day,assigned_zone,assigned_offset)
          VALUES(?,?,?,?,?,?,?,?,?,?)''',
          [
            f.uuid(200000 + n),
            f.uuid(5),
            f.quest().id.value,
            1,
            'time',
            1,
            DateTime.utc(2024, 2, 29).millisecondsSinceEpoch,
            '2024-02-29',
            'Etc/UTC',
            0,
          ],
        );
      }
      await batch.commit(noResult: true);
    });
    final plan = await db.rawQuery(
      "EXPLAIN QUERY PLAN SELECT SUM(delta) FROM ledger_entries WHERE assigned_day >= '2024-01-01' AND assigned_day <= '2024-12-31'",
    );
    expect(plan.toString(), contains('ledger_by_day'));
    final goalPlan = await db.rawQuery(
      "EXPLAIN QUERY PLAN SELECT COUNT(*) FROM daily_achievements WHERE day >= '2024-01-01' AND day <= '2024-12-31'",
    );
    expect(goalPlan.toString(), contains('achievements_by_day'));
    await db.close();
    await open();
    final watch = Stopwatch()..start();
    final year = await query(
      StatsMetric.questTime,
      period: StatsPeriod.yearly,
      day: DayKey(2024, 6, 1),
    );
    expect(year.length, 12);
    expect(total(year), 366 * 120000 + 1100);
    expect(
      (await query(StatsMetric.questTime, day: DayKey(2024, 2, 29)))[0].value,
      121100,
    );
    // Loose regression bound, not a device performance claim.
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test(
    'aggregate overflow is explicit and never rounded through REAL',
    () async {
      f.success(await store.write(f.seed));
      await store.close();
      final db = await databaseFactoryFfi.openDatabase(getPath());
      for (var n = 0; n < 2; n++) {
        await db.rawInsert(
          '''INSERT INTO ledger_entries
        (id,operation_id,item_id,item_revision,dimension,delta,assigned_utc,assigned_day,assigned_zone,assigned_offset)
        VALUES(?,?,?,?,?,?,?,?,?,?)''',
          [
            f.uuid(300000 + n),
            f.uuid(5),
            f.quest().id.value,
            1,
            'time',
            maxStoredInteger,
            DateTime.utc(2024).millisecondsSinceEpoch,
            '2024-01-01',
            'Etc/UTC',
            0,
          ],
        );
      }
      // Use the reader directly on the live SQL snapshot to check exactness at
      // the int64 limit before exercising the adapter's typed overflow result.
      await db.rawDelete('DELETE FROM ledger_entries WHERE id = ?', [
        f.uuid(300001),
      ]);
      final exact = await StoreReader(db, RecordCodec(f.metadata)).statistics(
        StatsQuery(
          period: StatsPeriod.yearly,
          anchor: DayKey(2024, 1, 1),
          category: StatsCategory.all,
          metric: StatsMetric.questTime,
        ),
      );
      expect(exact.first.value, maxStoredInteger);
      await db.rawInsert(
        '''INSERT INTO ledger_entries
        SELECT ?,operation_id,item_id,item_revision,session_id,dimension,
          budget_currency,budget_digits,delta,assigned_utc,assigned_day,
          assigned_zone,assigned_offset FROM ledger_entries WHERE id = ?''',
        [f.uuid(300001), f.uuid(300000)],
      );
      await db.close();
      await open();
      final corruptDaily = await stats.query(
        StatsQuery(
          period: StatsPeriod.daily,
          anchor: DayKey(2024, 1, 1),
          category: StatsCategory.all,
          metric: StatsMetric.questTime,
        ),
      );
      expect((corruptDaily as Failure).error, isA<StorageUnavailable>());
      final result = await stats.query(
        StatsQuery(
          period: StatsPeriod.yearly,
          anchor: DayKey(2024, 1, 1),
          category: StatsCategory.all,
          metric: StatsMetric.questTime,
        ),
      );
      expect((result as Failure).error, isA<NumericOverflow>());
    },
  );
}
