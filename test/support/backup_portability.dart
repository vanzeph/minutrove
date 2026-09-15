/// Cross-platform backup portability scenario, shared by the host FFI tests,
/// the on-device integration suites and the reference fixture generator.
///
/// The same deterministic history is rebuilt through the real product
/// repositories on every platform: host (sqflite_common_ffi), the iOS
/// simulator and the Android emulator (platform sqflite). Because every input
/// is pinned — UUIDs, operation serials, the clock and the reporting zone —
/// the exported `.minutrove` bytes are identical everywhere. The committed
/// reference fixture and its SHA-256 constant below prove that equality, so
/// restoring the reference on a platform is restoring a file produced by the
/// other one. Coverage intentionally includes multi-year history (2023–2026,
/// including a leap day, a midnight interval split and the 2023 Berlin
/// fall-back transition), every pinned currency precision (USD 2, JPY 0,
/// BHD 3 minor digits), archived Quest/Award items that keep balances, paid
/// daily-goal awards, and non-zero accrual remainder carry.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/data/pinned_currencies.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:sqflite_common/sqlite_api.dart';

const portabilityCurrencies = PinnedCurrencies();
final portabilityCalendar = IanaReportingCalendar();
final portabilityZone = ReportingZone('Europe/Berlin');
final portabilitySettings = AppSettings(
  revision: Revision(1),
  reportingZone: portabilityZone,
);

/// UTC instant the reference export samples the snapshot at (09:30 Berlin).
final DateTime portabilityCreatedUtc = DateTime.utc(2026, 3, 15, 8, 30);

/// SHA-256 of the committed reference fixture bytes, pinned by the generator.
/// Every platform's export must reproduce the reference bytes exactly.
const String portabilityReferenceSha256 =
    '6877409fc34fa4fa231159a10697372528ed676ab481ea78ac31be9392d23b6c';

/// Committed reference artifact, produced by
/// `dart run tool/generate_portability_fixture.dart` from the pinned toolchain.
const String portabilityReferencePath =
    'test/data/fixtures/portability-v1.minutrove';

/// Budget currencies covering every pinned minor-unit precision.
const List<String> portabilityBudgetCodes = ['USD', 'JPY', 'BHD'];

ItemId _id(int n) =>
    ItemId('00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}');
GroupId _groupId(int n) =>
    GroupId('00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}');
OperationId _opId(int n) =>
    OperationId('00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}');
final ItemId questWork = _id(101);
final ItemId questReading = _id(102);
final ItemId questStudy = _id(103);
final ItemId awardGaming = _id(201);
final ItemId awardCoffee = _id(202);
final ItemId awardCharm = _id(203);
final ItemId awardWalk = _id(204);
final GroupId focusGroup = _groupId(301);
final GroupId leisureGroup = _groupId(302);

class PortabilityClock implements Clock {
  DateTime utc = DateTime.utc(2023, 3, 6, 8);
  int monotonic = 1000;
  String boot = 'portability-fixture';

  /// Jump forward to a UTC instant; never backwards.
  void at(int year, int month, int day, int hourUtc, [int minute = 0]) {
    final time = DateTime.utc(year, month, day, hourUtc, minute);
    final delta = time.difference(utc).inMilliseconds;
    if (delta > 0) advance(delta);
  }

  void advance(int milliseconds) {
    utc = utc.add(Duration(milliseconds: milliseconds));
    monotonic += milliseconds;
  }

  @override
  ClockReading now() =>
      ClockReading(utc: utc, bootId: boot, monotonic: Milliseconds(monotonic));
}

/// One deterministic world: the live store plus the repository commands the
/// timeline drives. Rebuild repositories from `store` after any restore.
class PortabilityWorld {
  PortabilityWorld._({
    required this.store,
    required this.clock,
    required this.items,
    required this.sessions,
    required this.economy,
  });

  final SqliteStore store;
  final PortabilityClock clock;
  final SqliteItemRepository items;
  final SqliteSessionRepository sessions;
  final SqliteEconomyRepository economy;
  var _serial = 500;

  OperationId op() => OperationId(
    '00000000-0000-4000-8000-${(_serial++).toString().padLeft(12, '0')}',
  );

  Future<BackupFile> export() => _exportReference(store, clock);

  Future<void> close() => store.close();
}

Future<BackupFile> _exportReference(SqliteStore store, Clock clock) async {
  final result = await SqliteBackupExporter(
    store: store,
    clock: clock,
  ).exportBackup(operationId: _opId(499));
  if (result is Success<BackupFile>) return result.value;
  throw StateError('Portability export failed: ${(result as Failure).error}');
}

/// Opens a fresh store with the pinned production metadata and zone, runs the
/// deterministic multi-year timeline, and returns the live world.
Future<PortabilityWorld> buildPortabilityHistory({
  required String path,
  required DatabaseFactory factory,
}) async {
  final opened = await SqliteStore.open(
    path: path,
    factory: factory,
    currencies: portabilityCurrencies,
    initialSettings: portabilitySettings,
  );
  if (opened is Failure<SqliteStore>) {
    throw StateError('Portability store failed to open: ${opened.error}');
  }
  final store = (opened as Success<SqliteStore>).value;
  final clock = PortabilityClock();
  final world = PortabilityWorld._(
    store: store,
    clock: clock,
    items: SqliteItemRepository(
      store: store,
      clock: clock,
      calendar: portabilityCalendar,
    ),
    sessions: SqliteSessionRepository(
      store: store,
      clock: clock,
      calendar: portabilityCalendar,
    ),
    economy: SqliteEconomyRepository(
      store: store,
      clock: clock,
      calendar: portabilityCalendar,
    ),
  );
  await _runTimeline(world);
  return world;
}

T _ok<T>(Result<T> result) {
  if (result is Success<T>) return result.value;
  throw StateError('Portability command failed: ${(result as Failure).error}');
}

/// Unwraps a [Result] for assertions; portability flows are expected to pass.
T success<T>(Result<T> result) => _ok(result);

Item _quest(
  ItemId id,
  String name,
  GroupId? groupId,
  int order, {
  required int durationSeconds,
  required int coinsPerHour,
  required int gemsPerHour,
  (int, int)? goal, // (target seconds, coin bonus in millionths)
}) => Item(
  id: id,
  revision: Revision(1),
  name: name,
  iconKey: 'gamepad',
  colorArgb: 0xff883366,
  groupId: groupId,
  order: order,
  archived: false,
  configuration: QuestConfiguration(
    duration: Milliseconds.seconds(durationSeconds),
    ratesPerHour: CurrencyAmounts(
      coins: MicroAmount(coinsPerHour),
      gems: MicroAmount(gemsPerHour),
    ),
    dailyGoal: goal == null
        ? null
        : DailyGoal(
            target: Milliseconds.seconds(goal.$1),
            bonus: CurrencyAmounts(
              coins: MicroAmount(goal.$2),
              gems: MicroAmount(goal.$2 ~/ 10),
            ),
          ),
  ),
);

Item _award(
  ItemId id,
  String name,
  GroupId? groupId,
  int order, {
  required String pack,
  required int priceCoins,
  required int priceGems,
  int? timeGrantSeconds,
  (String, int)? budget, // (ISO code, minor units)
}) => Item(
  id: id,
  revision: Revision(1),
  name: name,
  iconKey: 'trove',
  colorArgb: 0xff336688,
  groupId: groupId,
  order: order,
  archived: false,
  configuration: AwardConfiguration(
    packName: pack,
    price: CurrencyAmounts(
      coins: MicroAmount(priceCoins),
      gems: MicroAmount(priceGems),
    ),
    timeGrant: timeGrantSeconds == null
        ? null
        : Milliseconds.seconds(timeGrantSeconds),
    budgetGrant: budget == null
        ? null
        : BudgetAmount(
            BudgetCurrency.fromMetadata(budget.$1, portabilityCurrencies),
            budget.$2,
          ),
  ),
);

Future<void> _runTimeline(PortabilityWorld w) async {
  // 2023-03-06 09:15 Berlin: definitions (goals effective from 03-07).
  w.clock.at(2023, 3, 6, 8, 15);
  _ok(
    await w.items.saveGroup(
      operationId: w.op(),
      group: Group(
        id: focusGroup,
        revision: Revision(1),
        name: 'Focus 深度',
        order: 0,
      ),
      expectedRevision: null,
    ),
  );
  _ok(
    await w.items.saveGroup(
      operationId: w.op(),
      group: Group(
        id: leisureGroup,
        revision: Revision(1),
        name: 'Leisure',
        order: 1,
      ),
      expectedRevision: null,
    ),
  );
  // Rates are deliberately not whole millionths-per-millisecond multiples, so
  // every earning quest keeps a non-zero accrual remainder across checkpoints.
  final work = _ok(
    await w.items.saveItem(
      operationId: w.op(),
      item: _quest(
        questWork,
        'Deep Work 学习 🎮',
        focusGroup,
        0,
        durationSeconds: 1800,
        coinsPerHour: 21599999999,
        gemsPerHour: 180000003,
        goal: (3600, 1000000),
      ),
      expectedRevision: null,
    ),
  );
  final reading = _ok(
    await w.items.saveItem(
      operationId: w.op(),
      item: _quest(
        questReading,
        'Reading',
        focusGroup,
        1,
        durationSeconds: 2700,
        coinsPerHour: 1000003,
        gemsPerHour: 0,
      ),
      expectedRevision: null,
    ),
  );
  final study = _ok(
    await w.items.saveItem(
      operationId: w.op(),
      item: _quest(
        questStudy,
        'Study',
        null,
        0,
        durationSeconds: 1200,
        coinsPerHour: 0,
        gemsPerHour: 7500003,
        goal: (1200, 500000),
      ),
      expectedRevision: null,
    ),
  );
  final gaming = _ok(
    await w.items.saveItem(
      operationId: w.op(),
      item: _award(
        awardGaming,
        'Gaming',
        leisureGroup,
        0,
        pack: 'Evening pack',
        priceCoins: 2500000000,
        priceGems: 50000000,
        timeGrantSeconds: 5400,
        budget: ('USD', 2500),
      ),
      expectedRevision: null,
    ),
  );
  final coffee = _ok(
    await w.items.saveItem(
      operationId: w.op(),
      item: _award(
        awardCoffee,
        'Coffee',
        leisureGroup,
        1,
        pack: 'Bag',
        priceCoins: 900000000,
        priceGems: 0,
        budget: ('JPY', 1500),
      ),
      expectedRevision: null,
    ),
  );
  final charm = _ok(
    await w.items.saveItem(
      operationId: w.op(),
      item: _award(
        awardCharm,
        'Gold Charm',
        null,
        0,
        pack: 'Charm',
        priceCoins: 0,
        priceGems: 300000000,
        budget: ('BHD', 12345),
      ),
      expectedRevision: null,
    ),
  );
  final walk = _ok(
    await w.items.saveItem(
      operationId: w.op(),
      item: _award(
        awardWalk,
        'Walk',
        null,
        1,
        pack: 'Loop',
        priceCoins: 100000000,
        priceGems: 0,
        timeGrantSeconds: 1200,
      ),
      expectedRevision: null,
    ),
  );

  Future<void> complete(Item quest, {int extraMilliseconds = 100}) async {
    final started = _ok(
      await w.sessions.startSession(
        operationId: w.op(),
        itemId: quest.id,
        expectedItemRevision: quest.revision,
        conflictChoice: SessionConflictChoice.cancel,
      ),
    );
    final duration = (quest.configuration as QuestConfiguration).duration.value;
    w.clock.advance(duration + extraMilliseconds);
    _ok(
      await w.sessions.reconcileSession(
        operationId: w.op(),
        sessionId: started.session.id,
      ),
    );
  }

  Future<void> endEarly(Item item, int activeMilliseconds) async {
    final started = _ok(
      await w.sessions.startSession(
        operationId: w.op(),
        itemId: item.id,
        expectedItemRevision: item.revision,
        conflictChoice: SessionConflictChoice.cancel,
      ),
    );
    w.clock.advance(activeMilliseconds);
    _ok(
      await w.sessions.endSession(
        operationId: w.op(),
        sessionId: started.session.id,
        expectedRevision: started.session.revision,
      ),
    );
  }

  // 2023-03-08: two full work sessions reach the one-hour goal (paid once).
  w.clock.at(2023, 3, 8, 9);
  await complete(work);
  w.clock.at(2023, 3, 8, 15);
  await complete(work);
  // First remainder carry: an early end settles 1 234 ms of active time.
  w.clock.at(2023, 3, 8, 20);
  await endEarly(reading, 1234);

  // 2023-07-14: full reading session in summer time (UTC+2).
  w.clock.at(2023, 7, 14, 9);
  await complete(reading);

  // 2023-10-28: a 45-minute run started 23:50 Berlin splits at local
  // midnight (10 min on the 28th, 35 min on the 29th).
  w.clock.at(2023, 10, 28, 21, 50);
  await complete(reading);

  // 2023-10-29: crossing the 03:00→02:00 fall-back; 20 study minutes start
  // 02:50 CEST and complete at 02:10 CET, paying the goal for that day.
  w.clock.at(2023, 10, 29, 0, 50);
  await complete(study, extraMilliseconds: 50);

  // 2024-02-29: leap-day goal achievement.
  w.clock.at(2024, 2, 29, 8);
  await complete(work);
  w.clock.at(2024, 2, 29, 13);
  await complete(work);

  // 2024-07-20: purchase, expense and partial time use of the combined
  // time+USD award.
  w.clock.at(2024, 7, 20, 10);
  final bought = _ok(
    await w.economy.redeemAward(
      operationId: w.op(),
      awardId: gaming.id,
      expectedRevision: gaming.revision,
      quantity: PurchaseQuantity(1),
    ),
  );
  _ok(
    await w.economy.recordExpense(
      operationId: w.op(),
      awardId: gaming.id,
      expectedBalanceRevision: bought.awards
          .firstWhere((a) => a.awardId == gaming.id)
          .revision,
      expense: BudgetAmount(
        BudgetCurrency.fromMetadata('USD', portabilityCurrencies),
        825,
      ),
      conflictChoice: SessionConflictChoice.cancel,
    ),
  );
  w.clock.at(2024, 7, 20, 19);
  await endEarly(gaming, 1500000);

  // 2024-11-03: study goal paid again.
  w.clock.at(2024, 11, 3, 16);
  await complete(study);

  // 2025-01-10: JPY (0 minor digits) purchase and expense.
  w.clock.at(2025, 1, 10, 9);
  final coffeeBought = _ok(
    await w.economy.redeemAward(
      operationId: w.op(),
      awardId: coffee.id,
      expectedRevision: coffee.revision,
      quantity: PurchaseQuantity(3),
    ),
  );
  _ok(
    await w.economy.recordExpense(
      operationId: w.op(),
      awardId: coffee.id,
      expectedBalanceRevision: coffeeBought.awards
          .firstWhere((a) => a.awardId == coffee.id)
          .revision,
      expense: BudgetAmount(
        BudgetCurrency.fromMetadata('JPY', portabilityCurrencies),
        420,
      ),
      conflictChoice: SessionConflictChoice.cancel,
    ),
  );

  // 2025-05-17: BHD (3 minor digits) purchase and expense.
  w.clock.at(2025, 5, 17, 11);
  final charmBought = _ok(
    await w.economy.redeemAward(
      operationId: w.op(),
      awardId: charm.id,
      expectedRevision: charm.revision,
      quantity: PurchaseQuantity(1),
    ),
  );
  _ok(
    await w.economy.recordExpense(
      operationId: w.op(),
      awardId: charm.id,
      expectedBalanceRevision: charmBought.awards
          .firstWhere((a) => a.awardId == charm.id)
          .revision,
      expense: BudgetAmount(
        BudgetCurrency.fromMetadata('BHD', portabilityCurrencies),
        1234,
      ),
      conflictChoice: SessionConflictChoice.cancel,
    ),
  );

  // 2025-09-21: time-only award, two packs, one partial run.
  w.clock.at(2025, 9, 21, 8);
  _ok(
    await w.economy.redeemAward(
      operationId: w.op(),
      awardId: walk.id,
      expectedRevision: walk.revision,
      quantity: PurchaseQuantity(2),
    ),
  );
  w.clock.at(2025, 9, 21, 17);
  await endEarly(walk, 300000);

  // 2025-12-31: a 17-minute early end leaves fresh remainder carry.
  w.clock.at(2025, 12, 31, 22);
  await endEarly(work, 1020000);

  // 2026-01-02: rename, then archive the quest with full history.
  w.clock.at(2026, 1, 2, 9);
  final renamed = _ok(
    await w.items.saveItem(
      operationId: w.op(),
      item: Item(
        id: work.id,
        revision: work.revision,
        name: 'Deep Work 已归档',
        iconKey: work.iconKey,
        colorArgb: work.colorArgb,
        groupId: work.groupId,
        order: work.order,
        archived: false,
        configuration: work.configuration,
      ),
      expectedRevision: work.revision,
    ),
  );
  _ok(
    await w.items.archiveItem(
      operationId: w.op(),
      itemId: work.id,
      expectedRevision: renamed.revision,
    ),
  );

  // 2026-01-15: study goal paid in a fourth calendar year.
  w.clock.at(2026, 1, 15, 7);
  await complete(study);

  // 2026-01-20: archive the BHD award while its balance is still positive.
  w.clock.at(2026, 1, 20, 10);
  _ok(
    await w.items.archiveItem(
      operationId: w.op(),
      itemId: charm.id,
      expectedRevision: charm.revision,
    ),
  );

  // 2026-02-14: remove the leisure group; the awards become Ungrouped today
  // while their historical revisions keep the removed group reference.
  w.clock.at(2026, 2, 14, 12);
  _ok(
    await w.items.removeGroup(
      operationId: w.op(),
      groupId: leisureGroup,
      expectedRevision: Revision(1),
    ),
  );

  w.clock.at(2026, 3, 15, 8, 30);
}

String _day(DayKey day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// A comparable projection of the durable domain state: wallet, award
/// balances (time + exact minor units per currency), per-quest remainder
/// carry, achievements, items (including archive state), groups, settings
/// and the full signed ledger. Ended sessions join via record-level export
/// comparison, which is exact.
Future<Map<String, Object>> portabilityDomainState(SqliteStore store) async {
  final state = _ok(
    await store.read(
      (r) async => (
        await r.wallet(),
        await r.awards(),
        await r.achievements(),
        await r.items(),
        await r.groups(),
        await r.settings(),
        await r.ledger(),
      ),
    ),
  );
  final remainders = _ok(
    await store.read((r) async {
      final quests = {questWork, questReading, questStudy};
      return [
        for (final quest in quests)
          for (final currency in VirtualCurrency.values)
            await r.remainder(quest, currency),
      ];
    }),
  );
  return {
    'wallet':
        '${state.$1.revision.value}:'
        '${state.$1.balances.coins.units}/${state.$1.balances.gems.units}',
    'awards': [
      for (final award in state.$2)
        '${award.awardId.value}:${award.revision.value}:'
            '${award.time?.value ?? '-'}:'
            '${award.budget?.currency.code ?? '-'}:'
            '${award.budget?.minorUnits ?? '-'}',
    ],
    'remainders': [
      for (final remainder in remainders)
        if (remainder != null)
          '${remainder.questId.value}:${remainder.currency.name}:'
              '${remainder.remainder.value}',
    ],
    'achievements': [
      for (final achievement in state.$3)
        '${achievement.questId.value}:${_day(achievement.day)}:'
            '${achievement.goalRevision.value}:'
            '${achievement.bonus.coins.units}/${achievement.bonus.gems.units}',
    ],
    'items': [
      for (final item in state.$4)
        '${item.id.value}:${item.revision.value}:${item.archived ? 'a' : 'v'}:'
            '${item.groupId?.value ?? '-'}:${item.name}',
    ],
    'groups': [for (final group in state.$5) '${group.id.value}:${group.name}'],
    'settings': '${state.$6.revision.value}:${state.$6.reportingZone.ianaName}',
    'ledger': [
      for (final entry in state.$7)
        '${entry.id.value}:${entry.dimension.toString()}:'
            '${_day(entry.timestamp.day)}:${entry.delta}',
    ],
  };
}

/// The frozen Stats battery: every compatible period, category, metric, item
/// (including archived history) and fixture budget currency. Comparing the
/// returned bucket lists between the source and restored store is the
/// Stats-agreement acceptance for a cross-platform restore.
Future<Map<String, List<String>>> portabilityStatsBattery(
  SqliteStore store,
) async {
  final anchor = DayKey(2026, 3, 15);
  // Per-item metrics stay within the repository's compatibility rules: award
  // time only where a time grant exists, budget metrics only on the award's
  // own currency. Archived items keep their full history in Stats.
  final items = <(ItemId, StatsMetric, BudgetCurrency?)>[
    (questWork, StatsMetric.questTime, null),
    (questWork, StatsMetric.coinsEarned, null),
    (questWork, StatsMetric.gemsEarned, null),
    (questReading, StatsMetric.questTime, null),
    (questReading, StatsMetric.coinsEarned, null),
    (questStudy, StatsMetric.questTime, null),
    (questStudy, StatsMetric.gemsEarned, null),
    (awardGaming, StatsMetric.awardTime, null),
    (awardGaming, StatsMetric.coinsSpent, null),
    (awardGaming, StatsMetric.gemsSpent, null),
    (
      awardGaming,
      StatsMetric.budgetSpent,
      BudgetCurrency.fromMetadata('USD', portabilityCurrencies),
    ),
    (awardCoffee, StatsMetric.coinsSpent, null),
    (
      awardCoffee,
      StatsMetric.budgetSpent,
      BudgetCurrency.fromMetadata('JPY', portabilityCurrencies),
    ),
    (awardCharm, StatsMetric.gemsSpent, null),
    (
      awardCharm,
      StatsMetric.budgetSpent,
      BudgetCurrency.fromMetadata('BHD', portabilityCurrencies),
    ),
    (awardWalk, StatsMetric.awardTime, null),
    (awardWalk, StatsMetric.coinsSpent, null),
  ];
  final stats = SqliteStatsRepository(store: store);
  final results = <String, List<String>>{};
  Future<void> run(String label, StatsQuery query) async {
    final buckets = _ok(await stats.query(query));
    results[label] = [
      for (final bucket in buckets)
        '${bucket.start.toUtc().toIso8601String()}|'
            '${bucket.end.toUtc().toIso8601String()}|${bucket.value}',
    ];
  }

  for (final period in StatsPeriod.values) {
    final suffix = period.name;
    await run(
      'questTime/all/$suffix',
      StatsQuery(
        period: period,
        anchor: anchor,
        category: StatsCategory.all,
        metric: StatsMetric.questTime,
      ),
    );
    await run(
      'questTime/quests/$suffix',
      StatsQuery(
        period: period,
        anchor: anchor,
        category: StatsCategory.quests,
        metric: StatsMetric.questTime,
      ),
    );
    await run(
      'awardTime/awards/$suffix',
      StatsQuery(
        period: period,
        anchor: anchor,
        category: StatsCategory.awards,
        metric: StatsMetric.awardTime,
      ),
    );
    for (final metric in [StatsMetric.coinsEarned, StatsMetric.gemsEarned]) {
      for (final category in [
        StatsCategory.all,
        StatsCategory.quests,
        StatsCategory.currencies,
      ]) {
        await run(
          '${metric.name}/${category.name}/$suffix',
          StatsQuery(
            period: period,
            anchor: anchor,
            category: category,
            metric: metric,
          ),
        );
      }
    }
    for (final metric in [StatsMetric.coinsSpent, StatsMetric.gemsSpent]) {
      for (final category in [
        StatsCategory.all,
        StatsCategory.awards,
        StatsCategory.currencies,
      ]) {
        await run(
          '${metric.name}/${category.name}/$suffix',
          StatsQuery(
            period: period,
            anchor: anchor,
            category: category,
            metric: metric,
          ),
        );
      }
    }
    await run(
      'dailyGoalCompletion/quests/$suffix',
      StatsQuery(
        period: period,
        anchor: anchor,
        category: StatsCategory.quests,
        metric: StatsMetric.dailyGoalCompletion,
      ),
    );
    for (final code in portabilityBudgetCodes) {
      final currency = BudgetCurrency.fromMetadata(code, portabilityCurrencies);
      for (final category in [StatsCategory.all, StatsCategory.awards]) {
        await run(
          'budgetSpent/$code/${category.name}/$suffix',
          StatsQuery(
            period: period,
            anchor: anchor,
            category: category,
            metric: StatsMetric.budgetSpent,
            budgetCurrency: currency,
          ),
        );
      }
    }
    for (final (id, metric, budgetCurrency) in items) {
      await run(
        'item/${id.value}/${metric.name}'
        '${budgetCurrency == null ? '' : '/${budgetCurrency.code}'}/$suffix',
        StatsQuery(
          period: period,
          anchor: anchor,
          category: StatsCategory.item,
          metric: metric,
          itemId: id,
          budgetCurrency: budgetCurrency,
        ),
      );
    }
  }
  return results;
}

/// Mutated backup bytes for failure-scenario tests on any platform:
/// `corrupt` flips one payload byte, `truncate` drops the tail, and
/// `future-version`/`foreign-currencies` rewrite JSON content with a freshly
/// computed integrity block, so the file is well-formed but semantically
/// unacceptable. Callers pass whichever bytes they hold (the committed
/// reference on host, an on-device export elsewhere).
BackupFile mutatedBackup(List<int> bytes, String mutation) {
  final mutated = List<int>.of(bytes);
  switch (mutation) {
    case 'corrupt':
      mutated[mutated.length ~/ 2] ^= 0x20;
    case 'truncate':
      mutated.removeRange(mutated.length - 100, mutated.length);
    case 'future-version':
      _rewriteEnvelope(mutated, (root) => root['version'] = 99);
    case 'foreign-currencies':
      _rewriteEnvelope(
        mutated,
        (root) =>
            (root['payload']!
                    as Map<String, Object?>)['currencyMetadataVersion'] =
                'pinned-iso4217-v2',
      );
    default:
      throw ArgumentError('Unknown mutation: $mutation');
  }
  return BackupFile(mutated);
}

/// Rewrites the JSON tree, then re-encodes the envelope canonically with a
/// freshly computed integrity block, so the mutated file is a well-formed
/// backup whose content differs rather than its digest.
void _rewriteEnvelope(
  List<int> bytes,
  void Function(Map<String, Object?>) edit,
) {
  final root = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
  edit(root);
  final payloadBytes = utf8.encode(_canonicalJson(root['payload']));
  root['integrity'] = {
    'algorithm': 'sha256',
    'payloadBytes': payloadBytes.length,
    'sha256': sha256.convert(payloadBytes).toString(),
  };
  final rewritten = utf8.encode(_canonicalJson(root));
  bytes
    ..clear()
    ..addAll(rewritten);
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

/// Structural coverage facts of a portability export, for acceptance
/// assertions: calendar years touched by durable event assignment, budget
/// precision classes present, archived items, achievements, and remainders.
Future<Map<String, Object>> portabilityCoverage(BackupFile file) async {
  final decoded = const BackupCodec().decode(file);
  final records = decoded.snapshot.records;
  final years = <int>{};
  for (final entry in records['ledger'] ?? const <Map<String, Object?>>[]) {
    final at = entry['at'] as Map<String, Object?>;
    years.add(int.parse((at['day'] as String).substring(0, 4)));
  }
  final precisions = <int>{};
  for (final balance
      in records['awardBalances'] ?? const <Map<String, Object?>>[]) {
    final budget = balance['budget'];
    if (budget is Map<String, Object?>) {
      precisions.add(
        portabilityCurrencies.minorDigitsFor(budget['currency'] as String)!,
      );
    }
  }
  return {
    'years': years.toList()..sort(),
    'budgetPrecisions': precisions.toList()..sort(),
    'archived': [
      for (final item in records['items'] ?? const <Map<String, Object?>>[])
        if (item['archived'] == true) item['id'],
    ],
    'achievements': (records['achievements'] ?? const []).length,
    'remaindersNonZero': [
      for (final remainder
          in records['accrualRemainders'] ?? const <Map<String, Object?>>[])
        if (remainder['value'] != '0') remainder['id'],
    ],
    'recordCounts': decoded.preview.recordCounts,
    'sha256': sha256.convert(file.bytes).toString(),
    'createdUtc': decoded.preview.createdUtc,
  };
}
