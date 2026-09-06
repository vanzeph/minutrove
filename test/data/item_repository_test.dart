import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support.dart' as f;

class TestClock implements Clock {
  DateTime utc = f.now;
  int monotonic = 0;
  @override
  ClockReading now() => ClockReading(
    utc: utc,
    bootId: 'test',
    monotonic: Milliseconds(monotonic),
  );
}

class TestCalendar implements ReportingCalendar {
  @override
  bool supports(ReportingZone zone) => zone.ianaName == f.zone.ianaName;
  @override
  EventTime assign(DateTime utc, ReportingZone zone) => EventTime(
    utc: utc,
    day: DayKey(utc.year, utc.month, utc.day),
    zone: zone,
    offsetSeconds: 0,
  );
  @override
  DateTime nextMidnight(EventTime time) =>
      DateTime.utc(time.day.year, time.day.month, time.day.day + 1);
}

Item edit(
  Item item, {
  String? name,
  String? icon,
  int? color,
  int? order,
  bool? archived,
  GroupId? group,
  ItemConfiguration? config,
}) => Item(
  id: item.id,
  revision: item.revision,
  name: name ?? item.name,
  iconKey: icon ?? item.iconKey,
  colorArgb: color ?? item.colorArgb,
  groupId: group ?? item.groupId,
  order: order ?? item.order,
  archived: archived ?? item.archived,
  configuration: config ?? item.configuration,
);
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqliteStore store;
  late SqliteItemRepository repo;
  late TestClock clock;
  var serial = 1000;
  OperationId op() => OperationId(f.uuid(serial++));
  Future<void> open() async {
    store = f.success(
      await SqliteStore.open(
        path: '${dir.path}/test.db',
        factory: databaseFactoryFfi,
        currencies: f.metadata,
        initialSettings: f.settings,
      ),
    );
    repo = SqliteItemRepository(
      store: store,
      clock: clock,
      calendar: TestCalendar(),
    );
  }

  Future<Item> save(Item item, {bool create = false}) async => f.success(
    await repo.saveItem(
      operationId: op(),
      item: item,
      expectedRevision: create ? null : item.revision,
    ),
  );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('minutrove-items-');
    clock = TestClock();
    await open();
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  test('creation assigns revisions; concurrent edits detect stale state; durable replay', () async {
    final id = op();
    final proposed = f.quest(revision: 99);
    final created = f.success(
      await repo.saveItem(
        operationId: id,
        item: proposed,
        expectedRevision: null,
      ),
    );
    expect(created.revision, Revision(1));
    final results = await Future.wait([
      repo.saveItem(
        operationId: op(),
        item: edit(created, name: 'First'),
        expectedRevision: created.revision,
      ),
      repo.saveItem(
        operationId: op(),
        item: edit(created, name: 'Second'),
        expectedRevision: created.revision,
      ),
    ]);
    expect(results.whereType<Success<Item>>().length, 1);
    expect(
      (results.whereType<Failure<Item>>().single).error,
      isA<StaleRevision>(),
    );
    await store.close();
    await open();
    final replay = f.success(
      await repo.saveItem(
        operationId: id,
        item: proposed,
        expectedRevision: null,
      ),
    );
    expect(replay.name, proposed.name);
    expect(replay.revision, Revision(1));
    expect(f.success(await repo.getItem(created.id))!.name, 'First');
    final wrongKind = await repo.saveGroup(
      operationId: id,
      group: f.group(),
      expectedRevision: null,
    );
    expect((wrongKind as Failure).error, isA<InvalidInput>());
    final changed = await repo.saveItem(
      operationId: id,
      item: edit(proposed, name: 'Other'),
      expectedRevision: null,
    );
    expect((changed as Failure).error, isA<InvalidInput>());
  });

  test('mixed groups rename/reorder/move and removal retain ordered immutable snapshots', () async {
    var g = f.success(
      await repo.saveGroup(
        operationId: op(),
        group: f.group(),
        expectedRevision: null,
      ),
    );
    g = f.success(
      await repo.saveGroup(
        operationId: op(),
        group: Group(
          id: g.id,
          revision: g.revision,
          name: 'Both types',
          order: 3,
        ),
        expectedRevision: g.revision,
      ),
    );
    final q = await save(edit(f.quest(), group: g.id, order: 4), create: true);
    final a = await save(
      edit(f.award(), group: g.id, order: 2, archived: true),
      create: true,
    );
    expect((await repo.watchGroups().first).single.name, 'Both types');
    expect((await repo.watchItems().first).map((x) => x.id), [a.id, q.id]);
    final id = op();
    final moved = f.success(
      await repo.removeGroup(
        operationId: id,
        groupId: g.id,
        expectedRevision: g.revision,
      ),
    );
    expect(moved.map((x) => x.groupId), [null, null]);
    expect(moved.map((x) => x.order), [2, 4]);
    expect(moved.map((x) => x.revision.value), [2, 2]);
    expect(moved.first.archived, isTrue);
    expect(await repo.watchGroups().first, isEmpty);
    f.success(
      await store.read((r) async {
        expect(
          (await r.itemRevision(q.id, Revision(1)))!.snapshot.groupId,
          g.id,
        );
        return true;
      }),
    );
    expect(
      f
          .success(
            await repo.removeGroup(
              operationId: id,
              groupId: g.id,
              expectedRevision: g.revision,
            ),
          )
          .length,
      2,
    );
    expect(
      (await repo.saveItem(
        operationId: op(),
        item: q,
        expectedRevision: q.revision,
      ) as Failure).error,
      isA<StaleRevision>(),
    );
    final bad = await repo.saveItem(
      operationId: op(),
      item: f.quest(n: 10, groupId: g.id),
      expectedRevision: null,
    );
    expect((bad as Failure).error, isA<NotFound>());
  });

  test('appearance/rate/pack edits preserve active snapshots, ledger and Trove; archive restores', () async {
    f.success(await store.write(f.seed));
    final q = f.success(await repo.getItem(f.quest().id))!;
    final updated = await save(
      edit(
        q,
        name: 'Renamed',
        icon: 'book',
        color: 0xff112233,
        config: QuestConfiguration(
          duration: Milliseconds.seconds(90),
          ratesPerHour: f.amounts(123),
          dailyGoal: (q.configuration as QuestConfiguration).dailyGoal,
        ),
      ),
    );
    final rejected = await repo.archiveItem(
      operationId: op(),
      itemId: q.id,
      expectedRevision: updated.revision,
    );
    expect((rejected as Failure).error, isA<ActiveSessionConflict>());
    var a = await save(
      edit(
        f.award(),
        config: AwardConfiguration(
          packName: 'New pack',
          price: f.amounts(3, 2),
          timeGrant: Milliseconds.seconds(120),
          budgetGrant: BudgetAmount(
            BudgetCurrency.fromMetadata('USD', f.metadata),
            2000,
          ),
        ),
      ),
    );
    a = f.success(
      await repo.archiveItem(
        operationId: op(),
        itemId: a.id,
        expectedRevision: a.revision,
      ),
    );
    expect(a.archived, isTrue);
    a = await save(edit(a, archived: false));
    expect(a.archived, isFalse);
    f.success(
      await store.read((r) async {
        expect((await r.activeSession())!.itemSnapshot.name, q.name);
        expect(
          ((await r.activeSession())!.itemSnapshot.configuration
                  as QuestConfiguration)
              .duration
              .value,
          60000,
        );
        expect((await r.award(a.id))!.time!.value, 60000);
        expect((await r.award(a.id))!.budget!.minorUnits, 1000);
        expect((await r.wallet()).balances.coins.units, 100);
        expect(
          (await r.remainder(q.id, VirtualCurrency.coins))!.remainder.value,
          1234,
        );
        expect((await r.goals(q.id)).length, 1);
        expect((await r.ledger()).length, 4);
        return true;
      }),
    );
  });

  test('history forbids type/currency/dimension changes, including exhausted allowances', () async {
    f.success(await store.write(f.seed));
    final a = f.award();
    for (final config in [
      f.quest().configuration,
      AwardConfiguration(
        packName: 'Other',
        price: f.amounts(1),
        timeGrant: Milliseconds.seconds(1),
      ),
      AwardConfiguration(
        packName: 'Other',
        price: f.amounts(1),
        timeGrant: Milliseconds.seconds(1),
        budgetGrant: BudgetAmount(
          BudgetCurrency.fromMetadata('JPY', f.metadata),
          1,
        ),
      ),
    ]) {
      final result = await repo.saveItem(
        operationId: op(),
        item: edit(a, config: config),
        expectedRevision: a.revision,
      );
      expect((result as Failure).error, isA<UnsupportedDimensionalEdit>());
    }
    final unused = await save(f.award(n: 40), create: true);
    expect(
      (await save(edit(unused, config: f.quest().configuration))).type,
      ItemType.quest,
    );
  });

  test('goal changes before activity apply today and after activity apply tomorrow', () async {
    var q = await save(f.quest(), create: true);
    QuestConfiguration goal(int seconds) => QuestConfiguration(
      duration: Milliseconds.seconds(60),
      ratesPerHour: f.amounts(1),
      dailyGoal: DailyGoal(
        target: Milliseconds.seconds(seconds),
        bonus: f.amounts(0),
      ),
    );
    q = await save(edit(q, config: goal(120)));
    expect(
      f.success(await store.read((r) => r.goals(q.id))).last.effectiveFrom,
      f.event.day,
    );
    f.success(
      await store.write(
        (tx) => tx.putSession(f.session(q, status: SessionStatus.paused)),
      ),
    );
    q = await save(edit(q, config: goal(180)));
    var goals = f.success(await store.read((r) => r.goals(q.id)));
    expect(goals.last.effectiveFrom, DayKey(2026, 1, 16));
    q = await save(
      edit(
        q,
        config: QuestConfiguration(
          duration: Milliseconds.seconds(60),
          ratesPerHour: f.amounts(1),
        ),
      ),
    );
    goals = f.success(await store.read((r) => r.goals(q.id)));
    expect(goals.last.goal, isNull);
    expect(goals.last.revision.value, 4);
    expect(goals.last.effectiveFrom, DayKey(2026, 1, 16));
  });

  test(
    'running time since checkpoint defers goal even without persisted activity',
    () async {
      var q = await save(f.quest(), create: true);
      final reading = clock.now();
      f.success(
        await store.write(
          (tx) => tx.putSession(
            Session(
              id: SessionId(f.uuid(90)),
              revision: Revision(1),
              itemSnapshot: q,
              status: SessionStatus.running,
              zone: f.zone,
              startedAt: reading,
              checkpoint: reading,
              duration: Milliseconds.seconds(60),
              settled: Milliseconds(0),
              deadlineUtc: f.now.add(const Duration(seconds: 60)),
              completionId: CompletionId(f.uuid(91)),
              intervals: [],
            ),
          ),
        ),
      );
      clock.utc = f.now.add(const Duration(seconds: 10));
      clock.monotonic = 10000;
      q = await save(
        edit(
          q,
          config: QuestConfiguration(
            duration: Milliseconds.seconds(60),
            ratesPerHour: f.amounts(1),
            dailyGoal: DailyGoal(
              target: Milliseconds.seconds(120),
              bonus: f.amounts(0),
            ),
          ),
        ),
      );
      expect(
        f.success(await store.read((r) => r.goals(q.id))).last.effectiveFrom,
        DayKey(2026, 1, 16),
      );
    },
  );

  test('failure after snapshot write rolls back revisions, membership and operation', () async {
    final g = f.success(
      await repo.saveGroup(
        operationId: op(),
        group: f.group(),
        expectedRevision: null,
      ),
    );
    final q = await save(edit(f.quest(), group: g.id), create: true);
    // A real SQLite failure on the final operation write happens after every
    // member has moved and the group has been deleted in the transaction.
    final db = await databaseFactoryFfi.openDatabase(
      '${dir.path}/test.db',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await db.execute(
      "CREATE TRIGGER fail_operation BEFORE INSERT ON operations BEGIN SELECT RAISE(ABORT, 'injected write failure'); END",
    );
    final id = op();
    expect(
      (await repo.removeGroup(
        operationId: id,
        groupId: g.id,
        expectedRevision: g.revision,
      ) as Failure).error,
      isA<StorageUnavailable>(),
    );
    f.success(
      await store.read((r) async {
        expect((await r.item(q.id))!.groupId, g.id);
        expect((await r.item(q.id))!.revision, Revision(1));
        expect(await r.itemRevision(q.id, Revision(2)), isNull);
        expect(await r.group(g.id), isNotNull);
        expect(await r.operation<Object>(id), isNull);
        return true;
      }),
    );
    await db.execute('DROP TRIGGER fail_operation');
    await db.close();
    expect(
      f
          .success(
            await repo.removeGroup(
              operationId: id,
              groupId: g.id,
              expectedRevision: g.revision,
            ),
          )
          .single
          .groupId,
      isNull,
    );
  });

  test('exhausted Award history still prevents dimension changes', () async {
    f.success(await store.write(f.seed));
    final a = f.award();
    f.success(
      await store.write((tx) async {
        await tx.insertOperation(f.operation(true, n: 80));
        await tx.insertLedger(
          f.entry(a, const TimeDimension(), -60000, n: 81, op: 80),
        );
        final currency = BudgetCurrency.fromMetadata('USD', f.metadata);
        await tx.insertLedger(
          f.entry(a, BudgetDimension(currency), -1000, n: 82, op: 80),
        );
        await tx.putAward(
          AwardBalance(
            awardId: a.id,
            revision: Revision(2),
            time: Milliseconds(0),
            budget: BudgetAmount(currency, 0),
          ),
        );
      }),
    );
    final result = await repo.saveItem(
      operationId: op(),
      expectedRevision: a.revision,
      item: edit(
        a,
        config: AwardConfiguration(
          packName: 'Time only',
          price: f.amounts(1),
          timeGrant: Milliseconds.seconds(1),
        ),
      ),
    );
    expect((result as Failure).error, isA<UnsupportedDimensionalEdit>());
  });

  test(
    'unknown group failures and closed-store writes publish no partial item',
    () async {
      final q = f.quest(groupId: f.group().id);
      final id = op();
      expect(
        (await repo.saveItem(
          operationId: id,
          item: q,
          expectedRevision: null,
        ) as Failure).error,
        isA<NotFound>(),
      );
      expect(await repo.watchItems().first, isEmpty);
      expect(
        f.success(await store.read((r) => r.operation<Object>(id))),
        isNull,
      );
      await store.close();
      expect(
        (await repo.saveItem(
          operationId: op(),
          item: f.quest(),
          expectedRevision: null,
        ) as Failure).error,
        isA<StorageUnavailable>(),
      );
    },
  );
}
