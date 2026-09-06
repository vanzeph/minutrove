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
  late Directory dir;
  late SqliteStore store;
  late EconomyRepository economy;
  late SqliteSessionRepository sessions;
  late SessionClock clock;
  final calendar = SessionCalendar();
  final usd = BudgetCurrency.fromMetadata('USD', f.metadata);
  var serial = 1000;
  OperationId op() => OperationId(f.uuid(serial++));
  String getPath() => '${dir.path}/test.db';
  Future<void> open({DatabaseFactory? factory}) async {
    store = f.success(
      await SqliteStore.open(
        path: getPath(),
        factory: factory ?? databaseFactoryFfi,
        currencies: f.metadata,
        initialSettings: f.settings,
      ),
    );
    economy = SqliteEconomyRepository(
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

  SqliteItemRepository items() =>
      SqliteItemRepository(store: store, clock: clock, calendar: calendar);
  Future<Item> save(Item item) async => f.success(
    await items().saveItem(
      operationId: op(),
      item: item,
      expectedRevision: null,
    ),
  );
  Future<SessionMutation> start(Item item) async => f.success(
    await sessions.startSession(
      operationId: op(),
      itemId: item.id,
      expectedItemRevision: item.revision,
      conflictChoice: SessionConflictChoice.cancel,
    ),
  );
  Future<SessionMutation> end(Session session) async => f.success(
    await sessions.endSession(
      operationId: op(),
      sessionId: session.id,
      expectedRevision: session.revision,
    ),
  );
  Future<AwardBalance> balance(Item item) async =>
      f.success(await store.read((r) => r.award(item.id)))!;
  Future<Result<EconomicState>> spend(
    Item item,
    AwardBalance owned, {
    OperationId? id,
    int cost = 1250,
    BudgetCurrency? currency,
    SessionConflictChoice choice = SessionConflictChoice.cancel,
  }) => economy.recordExpense(
    operationId: id ?? op(),
    awardId: item.id,
    expectedBalanceRevision: owned.revision,
    expense: BudgetAmount(currency ?? usd, cost),
    conflictChoice: choice,
  );
  Future<Item> ownedAward({
    bool time = true,
    bool budget = true,
    String currency = 'USD',
    int id = 2,
  }) async {
    final item = await save(
      Item(
        id: ItemId(f.uuid(id)),
        revision: Revision(1),
        name: 'Synthetic allowance',
        iconKey: 'gamepad',
        colorArgb: 0xff883366,
        groupId: null,
        order: id,
        archived: false,
        configuration: AwardConfiguration(
          packName: 'Pack',
          price: f.amounts(20, 2),
          timeGrant: time ? Milliseconds(60000) : null,
          budgetGrant: budget
              ? BudgetAmount(
                  BudgetCurrency.fromMetadata(currency, f.metadata),
                  3500,
                )
              : null,
        ),
      ),
    );
    f.success(
      await economy.redeemAward(
        operationId: op(),
        awardId: item.id,
        expectedRevision: item.revision,
        quantity: PurchaseQuantity(1),
      ),
    );
    return item;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('minutrove-consumption-');
    clock = SessionClock();
    await open();
    final q = await save(configuredQuest());
    final s = await start(q);
    clock.advance(300000);
    await end(s.session);
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  test('35.00 minus 12.50 retains 22.50 and all time without refunding Coins or Gems', () async {
    final a = await ownedAward();
    final before = await economy.watchWallet().first;
    final result = f.success(await spend(a, await balance(a)));
    expect(result.awards.single.budget!.minorUnits, 2250);
    expect(result.awards.single.time!.value, 60000);
    expect(result.awards.single.isExhausted, isFalse);
    expect(result.wallet.balances.coins, before.balances.coins);
    expect(result.wallet.balances.gems, before.balances.gems);
    expect(result.wallet.revision, before.revision);
    expect(result.entries.single.dimension, isA<BudgetDimension>());
    expect(result.entries.single.delta, -1250);
    expect(result.entries.single.sessionId, isNull);
    expect(result.entries.single.timestamp.utc, clock.utc);
    expect(
      f.success(await store.read((r) => r.projectionMismatches())),
      isEmpty,
    );
  });

  test(
    'budget-only and zero-decimal expenses use exact integer minor units',
    () async {
      final a = await ownedAward(time: false, currency: 'JPY');
      final result = f.success(
        await spend(
          a,
          await balance(a),
          currency: BudgetCurrency.fromMetadata('JPY', f.metadata),
        ),
      );
      expect(result.awards.single.time, isNull);
      expect(result.awards.single.budget.toString(), 'JPY 2250');
    },
  );

  test('invalid cost, currency, precision and revision leave the complete database unchanged', () async {
    final a = await ownedAward();
    final b = await balance(a);
    final before = await dump(getPath());
    for (final cost in [0, 3501, maxStoredInteger]) {
      expect(await spend(a, b, cost: cost), isA<Failure<EconomicState>>());
      expect(await dump(getPath()), before);
    }
    for (final text in ['-1', '1.001', 'NaN', 'Infinity']) {
      expect(() => BudgetAmount.parse(usd, text), throwsA(isA<DomainError>()));
      expect(await dump(getPath()), before);
    }
    for (final currency in [
      BudgetCurrency.fromMetadata('JPY', f.metadata),
      BudgetCurrency.fromMetadata('USD', const WrongPrecision()),
    ]) {
      expect(
        (await spend(a, b, currency: currency) as Failure).error,
        isA<InvalidInput>(),
      );
      expect(await dump(getPath()), before);
    }
    expect(
      (await economy.recordExpense(
        operationId: op(),
        awardId: a.id,
        expectedBalanceRevision: Revision(99),
        expense: BudgetAmount(usd, 1),
        conflictChoice: SessionConflictChoice.cancel,
      ) as Failure).error,
      isA<StaleRevision>(),
    );
    expect(await dump(getPath()), before);
  });

  test(
    'Quest, missing Award, and time-only allowance reject expenses',
    () async {
      final a = await ownedAward(budget: false);
      final before = await dump(getPath());
      for (final id in [a.id, ItemId(f.uuid(1)), ItemId(f.uuid(999))]) {
        expect(
          await economy.recordExpense(
            operationId: op(),
            awardId: id,
            expectedBalanceRevision: Revision(1),
            expense: BudgetAmount(usd, 1),
            conflictChoice: SessionConflictChoice.cancel,
          ),
          isA<Failure<EconomicState>>(),
        );
        expect(await dump(getPath()), before);
      }
    },
  );

  test('24 duplicates and restart replay the original result after later consumption', () async {
    final a = await ownedAward();
    final b = await balance(a);
    final id = op();
    final results = await Future.wait(
      List.generate(24, (_) => spend(a, b, id: id)),
    );
    final expected = RecordCodec(f.metadata).encode(f.success(results.first));
    for (final result in results) {
      expect(RecordCodec(f.metadata).encode(f.success(result)), expected);
    }
    f.success(await spend(a, await balance(a), cost: 250));
    final before = await dump(getPath());
    await store.close();
    await open();
    clock.unavailable = true;
    expect(
      RecordCodec(f.metadata).encode(f.success(await spend(a, b, id: id))),
      expected,
    );
    for (final request in [
      spend(a, b, id: id, cost: 100),
      spend(a, b, id: id, choice: SessionConflictChoice.endCurrentAndContinue),
      spend(
        a,
        b,
        id: id,
        currency: BudgetCurrency.fromMetadata('JPY', f.metadata),
      ),
      spend(a, await balance(a), id: id),
    ]) {
      expect((await request as Failure).error, isA<InvalidInput>());
    }
    expect(await dump(getPath()), before);
  });

  test('competing expenses at one revision cannot overdraw', () async {
    final a = await ownedAward();
    final b = await balance(a);
    final results = await Future.wait(
      List.generate(12, (_) => spend(a, b, cost: 3000)),
    );
    expect(results.whereType<Success<EconomicState>>().length, 1);
    expect(
      results.whereType<Failure<EconomicState>>().every(
        (r) => r.error is StaleRevision,
      ),
      isTrue,
    );
    expect((await balance(a)).budget!.minorUnits, 500);
  });

  for (final paused in [false, true]) {
    test(
      'expense cancel preserves the ${paused ? 'paused' : 'running'} slot; explicit continue settles and cancels intent',
      () async {
        final a = await ownedAward();
        final b = await balance(a);
        final q = f.success(await items().getItem(ItemId(f.uuid(1))))!;
        var active = (await start(q)).session;
        clock.advance(1000);
        if (paused) {
          active = f
              .success(
                await sessions.pauseSession(
                  operationId: op(),
                  sessionId: active.id,
                  expectedRevision: active.revision,
                ),
              )
              .session;
          clock.advance(100000);
        }
        final wallet = await economy.watchWallet().first;
        final before = await dump(getPath());
        expect(
          (await spend(a, b) as Failure).error,
          isA<ActiveSessionConflict>(),
        );
        expect(await dump(getPath()), before);
        expect(
          await spend(
            a,
            b,
            cost: 3501,
            choice: SessionConflictChoice.endCurrentAndContinue,
          ),
          isA<Failure<EconomicState>>(),
        );
        expect(await dump(getPath()), before);
        final result = f.success(
          await spend(
            a,
            b,
            choice: SessionConflictChoice.endCurrentAndContinue,
          ),
        );
        expect(result.activeSession, isNull);
        final settled = f.success(await sessions.getSession(active.id))!;
        expect(settled.status, SessionStatus.ended);
        expect(settled.settled.value, 1000);
        expect(
          result.wallet.balances.coins.units - wallet.balances.coins.units,
          paused ? 0 : 33333,
        );
        expect(result.awards.single.budget!.minorUnits, 2250);
        final intent = f
            .success(await store.read((r) => r.notificationIntents()))
            .singleWhere((i) => i.sessionId == active.id);
        expect(intent.deadlineUtc, isNull);
      },
    );
  }

  test('same Award time and expense settle independently in one command; stale revision is checked before settlement', () async {
    final a = await ownedAward();
    final b = await balance(a);
    final s = (await start(a)).session;
    clock.advance(12345);
    final result = f.success(
      await spend(a, b, choice: SessionConflictChoice.endCurrentAndContinue),
    );
    expect(result.awards.single.time!.value, 47655);
    expect(result.awards.single.budget!.minorUnits, 2250);
    expect(result.entries.map((e) => e.delta), [-12345, -1250]);
    expect(f.success(await sessions.getSession(s.id))!.settled.value, 12345);
    final before = await dump(getPath());
    expect((await spend(a, b) as Failure).error, isA<StaleRevision>());
    expect(await dump(getPath()), before);
  });

  test('early end, pause, exhaustion and replenishment retain only usable consumption routes', () async {
    final a = await ownedAward();
    expect(
      awardConsumptionActions(await balance(a)),
      AwardConsumptionAction.values,
    );
    final wallet = await economy.watchWallet().first;
    var s = (await start(a)).session;
    clock.advance(12345);
    s = f
        .success(
          await sessions.pauseSession(
            operationId: op(),
            sessionId: s.id,
            expectedRevision: s.revision,
          ),
        )
        .session;
    clock.advance(1000000);
    await end(s);
    expect((await balance(a)).time!.value, 47655);
    s = (await start(a)).session;
    clock.advance(1000000);
    await end(s);
    var b = await balance(a);
    expect(b.time!.value, 0);
    expect(b.isExhausted, isFalse);
    expect(awardConsumptionActions(b), [AwardConsumptionAction.recordExpense]);
    f.success(await spend(a, b, cost: 3500));
    b = await balance(a);
    expect(b.isExhausted, isTrue);
    expect(awardConsumptionActions(b), isEmpty);
    expect(await economy.watchAwards().first, hasLength(1));
    expect(f.success(await items().getItem(a.id)), isNotNull);
    final currentWallet = await economy.watchWallet().first;
    expect(currentWallet.balances.coins, wallet.balances.coins);
    expect(currentWallet.balances.gems, wallet.balances.gems);
    f.success(
      await economy.redeemAward(
        operationId: op(),
        awardId: a.id,
        expectedRevision: a.revision,
        quantity: PurchaseQuantity(1),
      ),
    );
    expect(await economy.watchAwards().first, hasLength(1));
    expect(
      awardConsumptionActions(await balance(a)),
      AwardConsumptionAction.values,
    );
  });

  test('budget exhaustion retains remaining time and archived allowance remains spendable', () async {
    final a = await ownedAward();
    f.success(
      await items().archiveItem(
        operationId: op(),
        itemId: a.id,
        expectedRevision: a.revision,
      ),
    );
    final result = f.success(await spend(a, await balance(a), cost: 3500));
    expect(result.awards.single.isExhausted, isFalse);
    expect(awardConsumptionActions(result.awards.single), [
      AwardConsumptionAction.useTime,
    ]);
    expect(result.entries.single.itemRevision, Revision(2));
  });

  for (final sameAward in [false, true]) {
    test(
      'expense with ${sameAward ? 'Award' : 'Quest'} settlement rolls back at every write and both COMMIT boundaries',
      () async {
        final a = await ownedAward();
        final b = await balance(a);
        final activeItem = sameAward
            ? a
            : f.success(await items().getItem(ItemId(f.uuid(1))))!;
        await start(activeItem);
        clock.advance(12345);
        final id = op();
        await store.close();
        final baseline = await File(getPath()).readAsBytes();
        final original = await dump(getPath());
        final factory = FaultFactory();
        await open(factory: factory);
        factory.arm();
        final fullResult = f.success(
          await spend(
            a,
            b,
            id: id,
            choice: SessionConflictChoice.endCurrentAndContinue,
          ),
        );
        final writes = factory.writes;
        factory.disarm();
        await store.close();
        final full = await dump(getPath());
        expect(writes, greaterThan(5));
        stdout.writeln(
          'Expense + ${sameAward ? 'Award' : 'Quest'} acceptance: $writes SQL writes and both COMMIT boundaries',
        );
        for (final boundary in [
          ...List.generate(writes, (i) => i + 1),
          -1,
          -2,
        ]) {
          await File(getPath()).writeAsBytes(baseline, flush: true);
          await open(factory: factory);
          factory.arm(failure: boundary);
          final failed = await spend(
            a,
            b,
            id: id,
            choice: SessionConflictChoice.endCurrentAndContinue,
          );
          expect(
            (failed as Failure).error,
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
          final retry = f.success(
            await spend(
              a,
              b,
              id: id,
              choice: SessionConflictChoice.endCurrentAndContinue,
            ),
          );
          expect(
            RecordCodec(f.metadata).encode(retry),
            RecordCodec(f.metadata).encode(fullResult),
          );
          await store.close();
          expect(await dump(getPath()), full, reason: 'retry $boundary');
        }
        await open();
      },
    );
  }
}

class WrongPrecision implements CurrencyMetadata {
  const WrongPrecision();
  @override
  String get version => 'wrong-test-metadata';
  @override
  int? minorDigitsFor(String code) => code == 'USD' ? 3 : null;
}
