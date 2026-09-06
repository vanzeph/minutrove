import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fault_database.dart';
import 'support.dart' as f;

const coins = VirtualCurrencyDimension(VirtualCurrency.coins);
const gems = VirtualCurrencyDimension(VirtualCurrency.gems);
final usd = BudgetCurrency.fromMetadata('USD', f.metadata);

class TestClock implements Clock {
  int calls = 0;
  @override
  ClockReading now() {
    calls++;
    return ClockReading(utc: f.now, bootId: 'test', monotonic: Milliseconds(0));
  }
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
  DateTime nextMidnight(EventTime time) => throw UnimplementedError();
}

Item award({
  int n = 2,
  int revision = 1,
  CurrencyAmounts? price,
  int? time = 600000,
  int? budget = 1000,
  bool archived = false,
}) => Item(
  id: ItemId(f.uuid(n)),
  revision: Revision(revision),
  name: 'Synthetic Award',
  iconKey: 'gamepad',
  colorArgb: 0xff883366,
  groupId: null,
  order: 0,
  archived: archived,
  configuration: AwardConfiguration(
    packName: 'Pack',
    price: price ?? f.amounts(20, 2),
    timeGrant: time == null ? null : Milliseconds(time),
    budgetGrant: budget == null ? null : BudgetAmount(usd, budget),
  ),
);

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late String path;
  late SqliteStore store;
  late SqliteAwardRedemptionRepository repo;
  late TestClock clock;
  int ledgerSerial = 1000;
  Future<void> open({DatabaseFactory? factory}) async {
    store = f.success(
      await SqliteStore.open(
        path: path,
        factory: factory ?? databaseFactoryFfi,
        currencies: f.metadata,
        initialSettings: f.settings,
      ),
    );
    repo = SqliteAwardRedemptionRepository(
      store: store,
      clock: clock,
      calendar: TestCalendar(),
      newLedgerId: () => LedgerId(f.uuid(ledgerSerial++)),
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('minutrove-redemption-');
    path = '${directory.path}/test.db';
    clock = TestClock();
    ledgerSerial = 1000;
    await open();
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  Future<void> seed({
    Item? item,
    int walletCoins = 100,
    int walletGems = 10,
    int? ownedTime,
    int? ownedBudget,
  }) async {
    final a = item ?? award();
    f.success(
      await store.write((r) async {
        await r.putItem(ItemRevision(snapshot: f.quest(), recordedAt: f.event));
        await r.putItem(ItemRevision(snapshot: a, recordedAt: f.event));
      }),
    );
    f.success(
      await CommandCoordinator(store).execute(
        operationId: OperationId(f.uuid(10)),
        request: CommandRequest(
          kind: OperationKind.reconcileSession,
          arguments: {},
        ),
        committedAt: (_) => f.event,
        action: (command) async {
          await command.postLedger([
            if (walletCoins > 0)
              f.entry(f.quest(), coins, walletCoins, op: 10, n: 11),
            if (walletGems > 0)
              f.entry(f.quest(), gems, walletGems, op: 10, n: 12),
            if (ownedTime != null)
              f.entry(a, const TimeDimension(), ownedTime, op: 10, n: 13),
            if (ownedBudget != null)
              f.entry(a, BudgetDimension(usd), ownedBudget, op: 10, n: 14),
          ]);
          return command.economicState();
        },
      ),
    );
  }

  Future<Result<EconomicState>> buy({
    int op = 20,
    int n = 2,
    int revision = 1,
    int quantity = 3,
  }) => repo.redeemAward(
    operationId: OperationId(f.uuid(op)),
    awardId: ItemId(f.uuid(n)),
    expectedRevision: Revision(revision),
    quantity: PurchaseQuantity(quantity),
  );
  Future<Result<RedemptionPreview>> preview({int n = 2, int quantity = 3}) =>
      repo.previewAward(
        awardId: ItemId(f.uuid(n)),
        quantity: PurchaseQuantity(quantity),
      );
  Future<void> audit() async => expect(
    f.success(await store.read((r) => r.projectionMismatches())),
    isEmpty,
  );
  Future<String> snapshot() => store
      .read(
        (r) async => [
          r.codec.encode(await r.wallet()),
          (await r.awards()).map(r.codec.encode).toList().toString(),
          (await r.ledger()).map(r.codec.encode).toList().toString(),
        ].toString(),
      )
      .then(f.success);
  Future<void> rejected<T>(
    Result<T> result,
    Matcher error,
    String before,
  ) async {
    expect(result, isA<Failure<T>>().having((v) => v.error, 'error', error));
    expect(await snapshot(), before);
    expect(
      f.success(
        await store.read((r) => r.operation<Object>(OperationId(f.uuid(20)))),
      ),
      isNull,
    );
    await audit();
  }

  test('quote is read-only; three packs pool 45 minutes into one 75-minute balance', () async {
    await seed(ownedTime: 2700000, ownedBudget: 3500);
    final before = await snapshot();
    final quote = f.success(await preview());
    expect(quote.itemRevision, Revision(1));
    expect(quote.quantity.value, 3);
    expect(quote.totalPrice.coins.units, 60);
    expect(quote.totalPrice.gems.units, 6);
    expect(quote.timeGrant!.value, 1800000);
    expect(quote.budgetGrant!.minorUnits, 3000);
    expect(quote.walletAfter.coins.units, 40);
    expect(quote.walletAfter.gems.units, 4);
    expect(quote.maximumAffordableQuantity, 5);
    expect(await snapshot(), before); // Cancel simply discards this quote.
    expect(clock.calls, 0);
    final result = f.success(await buy());
    expect(result.awards, hasLength(1));
    expect(result.awards.single.time!.value, 4500000);
    expect(result.awards.single.budget!.minorUnits, 6500);
    expect(result.awards.single.revision, Revision(2));
    expect(result.wallet.balances.coins.units, 40);
    expect(result.wallet.balances.gems.units, 4);
    expect(result.entries, hasLength(4));
    expect(
      result.entries.map((e) => e.delta),
      unorderedEquals([-60, -6, 1800000, 3000]),
    );
    expect(
      result.entries.every(
        (e) =>
            e.itemRevision == Revision(1) &&
            e.sessionId == null &&
            e.timestamp.utc == f.now,
      ),
      isTrue,
    );
    expect(result.achievements, isEmpty);
    await audit();
  });

  for (final dimension in ['time', 'budget', 'both']) {
    for (final currency in ['coins', 'gems', 'both']) {
      test(
        '$dimension grants and $currency prices create exactly one allowance at max quantity',
        () async {
          await seed(
            item: award(
              time: dimension == 'budget' ? null : 600000,
              budget: dimension == 'time' ? null : 1000,
              price: f.amounts(
                currency == 'gems' ? 0 : 20,
                currency == 'coins' ? 0 : 2,
              ),
            ),
          );
          final result = f.success(await buy(quantity: 5));
          final balance = result.awards.single;
          expect(balance.time?.value, dimension == 'budget' ? null : 3000000);
          expect(balance.budget?.minorUnits, dimension == 'time' ? null : 5000);
          expect(
            result.wallet.balances.coins.units,
            currency == 'gems' ? 100 : 0,
          );
          expect(
            result.wallet.balances.gems.units,
            currency == 'coins' ? 10 : 0,
          );
          await audit();
        },
      );
    }
  }

  for (final shortage in ['coins', 'gems', 'both']) {
    test(
      'insufficient $shortage rejects the complete purchase and can retry after funding',
      () async {
        await seed(
          walletCoins: shortage == 'gems' ? 100 : 59,
          walletGems: shortage == 'coins' ? 10 : 5,
        );
        final before = await snapshot();
        final expected = isA<InsufficientFunds>()
            .having((e) => e.coins, 'coins', shortage != 'gems')
            .having((e) => e.gems, 'gems', shortage != 'coins');
        await rejected(await preview(), expected, before);
        await rejected(await buy(), expected, before);
        f.success(
          await CommandCoordinator(store).execute(
            operationId: OperationId(f.uuid(30)),
            request: CommandRequest(
              kind: OperationKind.reconcileSession,
              arguments: {},
            ),
            committedAt: (_) => f.event,
            action: (c) async {
              await c.postLedger([
                f.entry(f.quest(), coins, 100, op: 30, n: 31),
                f.entry(f.quest(), gems, 10, op: 30, n: 32),
              ]);
              return c.economicState();
            },
          ),
        );
        f.success(await buy());
        await audit();
      },
    );
  }

  test('price edits reject stale quote; refresh buys new grants without rewriting history', () async {
    await seed(ownedTime: 2700000, ownedBudget: 3500);
    f.success(await preview());
    f.success(
      await store.write(
        (r) => r.putItem(
          ItemRevision(
            snapshot: award(
              revision: 2,
              price: f.amounts(10, 1),
              time: 1200000,
              budget: 2000,
            ),
            recordedAt: f.event,
          ),
        ),
      ),
    );
    final before = await snapshot();
    await rejected(await buy(), isA<StaleRevision>(), before);
    final refreshed = f.success(await preview());
    expect(refreshed.itemRevision, Revision(2));
    expect(refreshed.totalPrice.coins.units, 30);
    final result = f.success(await buy(revision: 2));
    expect(result.awards.single.time!.value, 6300000);
    expect(result.awards.single.budget!.minorUnits, 9500);
    expect(result.entries.every((e) => e.itemRevision == Revision(2)), isTrue);
    final old = f.success(
      await store.read((r) => r.itemRevision(award().id, Revision(1))),
    )!;
    expect(
      (old.snapshot.configuration as AwardConfiguration).timeGrant!.value,
      600000,
    );
    await audit();
  });

  test('24 duplicates replay original result even after later purchase, archive and reopen', () async {
    await seed();
    final results = await Future.wait(List.generate(24, (_) => buy()));
    const codec = RecordCodec(f.metadata);
    final original = codec.encode(f.success(results.first));
    expect(
      results.map((r) => codec.encode(f.success(r))),
      everyElement(original),
    );
    expect(clock.calls, 1);
    f.success(await buy(op: 21, quantity: 1));
    f.success(
      await store.write(
        (r) => r.putItem(
          ItemRevision(
            snapshot: award(revision: 2, archived: true),
            recordedAt: f.event,
          ),
        ),
      ),
    );
    await store.close();
    await open();
    expect(codec.encode(f.success(await buy())), original);
    expect(clock.calls, 2);
    final before = await snapshot();
    for (final result in [
      await buy(quantity: 1),
      await buy(n: 99),
      await buy(revision: 2),
    ]) {
      expect(
        result,
        isA<Failure<EconomicState>>().having(
          (e) => e.error,
          'error',
          isA<InvalidInput>(),
        ),
      );
    }
    expect(await snapshot(), before);
    expect((await repo.watchAwards().first).single.time!.value, 2400000);
    await audit();
  });

  test(
    'competing distinct submissions recheck current wallet and never overdraw',
    () async {
      await seed();
      final results = await Future.wait([buy(), buy(op: 21)]);
      expect(results.whereType<Success<EconomicState>>(), hasLength(1));
      expect(
        results.whereType<Failure<EconomicState>>().single.error,
        isA<InsufficientFunds>(),
      );
      expect((await repo.watchWallet().first).balances.coins.units, 40);
      expect((await repo.watchAwards().first).single.time!.value, 1800000);
      await audit();
    },
  );

  test('missing, Quest and archived definitions are not purchasable', () async {
    await seed(
      item: award(archived: true),
      ownedTime: 600000,
      ownedBudget: 1000,
    );
    final before = await snapshot();
    await rejected(await preview(n: 99), isA<NotFound>(), before);
    await rejected(await buy(n: 99), isA<NotFound>(), before);
    for (final n in [1, 2]) {
      await rejected(await preview(n: n), isA<InvalidInput>(), before);
      await rejected(await buy(n: n), isA<InvalidInput>(), before);
    }
    expect((await repo.watchAwards().first).single.time!.value, 600000);
  });

  for (final status in [SessionStatus.running, SessionStatus.paused]) {
    test(
      'purchase while $status preserves session and notification intent',
      () async {
        await seed();
        final session = f.session(f.quest(), status: status);
        final intent = NotificationIntent(
          sessionId: session.id,
          sessionRevision: session.revision,
          completionId: session.completionId,
          deadlineUtc: session.deadlineUtc,
          completionChimeHandled: false,
        );
        f.success(
          await store.write((r) async {
            await r.putSession(session);
            await r.putNotificationIntent(intent);
          }),
        );
        final result = f.success(await buy());
        const codec = RecordCodec(f.metadata);
        expect(codec.encode(result.activeSession!), codec.encode(session));
        expect(
          codec.encode(
            f.success(await store.read((r) => r.notificationIntents())).single,
          ),
          codec.encode(intent),
        );
        await audit();
      },
    );
  }

  for (final overflow in [
    'price',
    'time product',
    'budget product',
    'pooled time',
    'pooled budget',
  ]) {
    test(
      '$overflow overflow changes neither currency, allowance nor history',
      () async {
        await seed(
          item: award(
            price: overflow == 'price'
                ? f.amounts(maxStoredInteger)
                : f.amounts(1),
            time: overflow == 'time product'
                ? maxStoredInteger - maxStoredInteger % 1000
                : 600000,
            budget: overflow == 'budget product' ? maxStoredInteger : 1000,
          ),
          walletCoins: maxStoredInteger,
          ownedTime: overflow == 'pooled time' ? maxStoredInteger : null,
          ownedBudget: overflow == 'pooled budget' ? maxStoredInteger : null,
        );
        final before = await snapshot();
        await rejected(await preview(), isA<NumericOverflow>(), before);
        await rejected(await buy(), isA<NumericOverflow>(), before);
      },
    );
  }

  test(
    'whole pack quantity and upper integer bound use checked arithmetic',
    () async {
      expect(() => PurchaseQuantity(0), throwsA(isA<InvalidInput>()));
      expect(() => PurchaseQuantity(-1), throwsA(isA<InvalidInput>()));
      await seed(
        item: award(price: f.amounts(1), time: null, budget: 1),
        walletCoins: maxStoredInteger,
        walletGems: 0,
      );
      final quote = f.success(await preview(quantity: maxStoredInteger));
      expect(quote.maximumAffordableQuantity, maxStoredInteger);
      final result = f.success(await buy(quantity: maxStoredInteger));
      expect(result.awards.single.budget!.minorUnits, maxStoredInteger);
      expect(result.wallet.balances.isZero, isTrue);
      await audit();
    },
  );

  test(
    'watchers expose only committed balances and retain exhausted dimensions',
    () async {
      await seed(ownedTime: 0, ownedBudget: 0);
      final wallets = StreamIterator(repo.watchWallet());
      final awards = StreamIterator(repo.watchAwards());
      expect(await wallets.moveNext(), isTrue);
      expect(await awards.moveNext(), isTrue);
      expect(awards.current.single.isExhausted, isTrue);
      final walletChange = wallets.moveNext();
      final awardChange = awards.moveNext();
      f.success(await buy());
      expect(await walletChange, isTrue);
      expect(await awardChange, isTrue);
      expect(wallets.current.balances.coins.units, 40);
      expect(awards.current.single.time!.value, 1800000);
      expect(awards.current.single.isExhausted, isFalse);
      await wallets.cancel();
      await awards.cancel();
    },
  );

  test('every redemption write and COMMIT failure rolls back or replays exactly once', () async {
    await seed(ownedTime: 2700000, ownedBudget: 3500);
    await store.close();
    final baseline = await File(path).readAsBytes();
    final factory = FaultFactory();
    await open(factory: factory);
    factory.arm();
    final result = f.success(await buy());
    final writes = factory.writes;
    expect(writes, greaterThanOrEqualTo(7));
    // ignore: avoid_print
    print(
      'Redemption acceptance: $writes SQL writes and both COMMIT boundaries',
    );
    factory.disarm();
    await store.close();
    final full = await dump(path);
    const codec = RecordCodec(f.metadata);
    for (final failure in [...List.generate(writes, (i) => i + 1), -1, -2]) {
      await File(path).writeAsBytes(baseline, flush: true);
      await open(factory: factory);
      ledgerSerial = 1000;
      factory.arm(failure: failure);
      expect(
        await buy(),
        isA<Failure<EconomicState>>(),
        reason: 'boundary $failure',
      );
      factory.disarm();
      await store.close();
      if (failure == -2) {
        expect(await dump(path), full);
      } else {
        expect(
          await File(path).readAsBytes(),
          baseline,
          reason: 'boundary $failure',
        );
      }
      await open(factory: factory);
      ledgerSerial = 1000;
      expect(codec.encode(f.success(await buy())), codec.encode(result));
      await audit();
      await store.close();
      expect(await dump(path), full, reason: 'retry boundary $failure');
    }
    await open();
  });
}
