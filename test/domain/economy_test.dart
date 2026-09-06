import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/domain/domain.dart';

import 'items_test.dart' show item, money;
import 'values_test.dart' show TestCurrencies;

CurrencyAccrualRemainders remainders([int coins = 0, int gems = 0]) =>
    (coins: AccrualRemainder(coins), gems: AccrualRemainder(gems));

void main() {
  final usd = BudgetCurrency.fromMetadata('USD', TestCurrencies());
  final jpy = BudgetCurrency.fromMetadata('JPY', TestCurrencies());
  final kwd = BudgetCurrency.fromMetadata('KWD', TestCurrencies());

  test('five active minutes retain exactly 10 Coins and 0.2 Gems', () {
    final rates = CurrencyAmounts(
      coins: normalizeRatePerHour('2', per: TimeUnit.minutes),
      gems: normalizeRatePerHour('0.04', per: TimeUnit.minutes),
    );
    final result = accrueCurrencies(
      ratesPerHour: rates,
      active: Milliseconds.seconds(300),
      remainders: remainders(),
    );
    expect(result.amounts.coins.toString(), '10.000000');
    expect(result.amounts.gems.toString(), '0.200000');
    expect(result.remainders.coins.value, 0);
    expect(result.remainders.gems.value, 0);
  });

  test('seeded random partitions equal combined accrual and BigInt oracle', () {
    final random = Random(64006);
    for (var sample = 0; sample < 300; sample++) {
      final rates = money(random.nextInt(1 << 30), random.nextInt(1 << 30));
      final initial = remainders(
        random.nextInt(3600000),
        random.nextInt(3600000),
      );
      var carry = initial;
      var total = money(0);
      var elapsed = 0;
      for (var part = 0; part < 1 + sample % 71; part++) {
        final active = random.nextInt(7200000);
        elapsed += active;
        final result = accrueCurrencies(
          ratesPerHour: rates,
          active: Milliseconds(active),
          remainders: carry,
        );
        total = total + result.amounts;
        // Simulate storage/reload at each checkpoint or session end.
        carry = remainders(
          result.remainders.coins.value,
          result.remainders.gems.value,
        );
      }
      final combined = accrueCurrencies(
        ratesPerHour: rates,
        active: Milliseconds(elapsed),
        remainders: initial,
      );
      expect(total.coins, combined.amounts.coins, reason: 'sample $sample');
      expect(total.gems, combined.amounts.gems, reason: 'sample $sample');
      expect(carry.coins.value, combined.remainders.coins.value);
      expect(carry.gems.value, combined.remainders.gems.value);
      for (final entry in [
        (rates.coins, initial.coins, total.coins, carry.coins),
        (rates.gems, initial.gems, total.gems, carry.gems),
      ]) {
        final exact =
            BigInt.from(entry.$1.units) * BigInt.from(elapsed) +
            BigInt.from(entry.$2.value);
        expect(
          BigInt.from(entry.$3.units) * BigInt.from(3600000) +
              BigInt.from(entry.$4.value),
          exact,
        );
      }
    }
  });

  test(
    'paused checkpoints and changed rates retain independent remainders',
    () {
      final initial = remainders(3599999, 17);
      final paused = accrueCurrencies(
        ratesPerHour: money(1, 100),
        active: Milliseconds(0),
        remainders: initial,
      );
      expect(paused.amounts.isZero, isTrue);
      final resumed = accrueCurrencies(
        ratesPerHour: money(1, 0),
        active: Milliseconds(1),
        remainders: paused.remainders,
      );
      expect(resumed.amounts.coins.units, 1);
      expect(resumed.amounts.gems.units, 0);
      expect(resumed.remainders.coins.value, 0);
      expect(resumed.remainders.gems.value, 17);
      expect(initial.coins.value, 3599999);
    },
  );

  test('large accrual intermediates narrow only after division', () {
    final result = accrueCurrencies(
      ratesPerHour: money(maxStoredInteger, 1),
      active: Milliseconds(3600000),
      remainders: remainders(3599999, 0),
    );
    expect(result.amounts.coins.units, maxStoredInteger);
    expect(result.remainders.coins.value, 3599999);
    expect(result.amounts.gems.units, 1);
    expect(
      () => accrueCurrencies(
        ratesPerHour: money(1, maxStoredInteger),
        active: Milliseconds(3600001),
        remainders: remainders(),
      ),
      throwsA(isA<NumericOverflow>()),
    );
    expect(() => AccrualRemainder(-1), throwsA(isA<InvalidInput>()));
  });

  test(
    'normalization preserves the smallest rate and checks its final bound',
    () {
      expect(
        normalizeRatePerHour('0.000001', per: TimeUnit.seconds).units,
        3600,
      );
      expect(normalizeRatePerHour('0.000001', per: TimeUnit.minutes).units, 60);
      expect(normalizeRatePerHour('0.000001', per: TimeUnit.hours).units, 1);
      expect(normalizeRatePerHour('0', per: TimeUnit.minutes).units, 0);
      expect(
        normalizeRatePerHour(
          '153722867280.912930',
          per: TimeUnit.minutes,
        ).units,
        maxStoredInteger - 7,
      );
      expect(
        () =>
            normalizeRatePerHour('153722867280.912931', per: TimeUnit.minutes),
        throwsA(isA<NumericOverflow>()),
      );
      for (final invalid in [
        '0.0000001',
        '1e-6',
        'NaN',
        'Infinity',
        '-1',
        '1.0000000',
      ]) {
        expect(
          () => normalizeRatePerHour(invalid, per: TimeUnit.hours),
          throwsA(isA<InvalidInput>()),
        );
      }
    },
  );

  test('time editor requires exact positive whole seconds in each unit', () {
    expect(
      Milliseconds.parseConfiguration('0.05', unit: TimeUnit.minutes),
      Milliseconds.seconds(3),
    );
    expect(
      Milliseconds.parseConfiguration('0.0025', unit: TimeUnit.hours),
      Milliseconds.seconds(9),
    );
    expect(
      Milliseconds.parseConfiguration('1.5', unit: TimeUnit.minutes),
      Milliseconds.seconds(90),
    );
    expect(
      Milliseconds.parseConfiguration('1.000000', unit: TimeUnit.seconds),
      Milliseconds.seconds(1),
    );
    // The scaled input exceeds int64, but the final milliseconds fit.
    expect(
      Milliseconds.parseConfiguration(
        '9223372036854775',
        unit: TimeUnit.seconds,
      ).value,
      9223372036854775000,
    );
    expect(
      () => Milliseconds.parseConfiguration(
        '9223372036854776',
        unit: TimeUnit.seconds,
      ),
      throwsA(isA<NumericOverflow>()),
    );
    for (final unit in TimeUnit.values) {
      for (final invalid in [
        '0',
        '-1',
        '0.000001',
        '1.0000000',
        'NaN',
        '1e3',
      ]) {
        expect(
          () => Milliseconds.parseConfiguration(invalid, unit: unit),
          throwsA(isA<InvalidInput>()),
        );
      }
    }
  });

  test(
    'time pooling and consumption preserve unused allowance and cap overshoot',
    () {
      final available =
          Milliseconds.seconds(45 * 60) +
          Milliseconds.seconds(10 * 60).times(3);
      expect(available, Milliseconds.seconds(75 * 60));
      final used = available.consume(Milliseconds(1234));
      expect(used.consumed.value, 1234);
      expect(used.remaining.value, available.value - 1234);
      expect(used.remaining.consume(Milliseconds(0)).remaining, used.remaining);
      expect(
        used.remaining.consume(Milliseconds(maxStoredInteger)).remaining.value,
        0,
      );
      expect(Milliseconds(0).consume(Milliseconds(1)).consumed.value, 0);
      expect(
        () => Milliseconds(maxStoredInteger) + Milliseconds(1),
        throwsA(isA<NumericOverflow>()),
      );
      expect(
        () => Milliseconds(maxStoredInteger).times(2),
        throwsA(isA<NumericOverflow>()),
      );
      expect(
        () => Milliseconds(0) - Milliseconds(1),
        throwsA(isA<AllowanceExceeded>()),
      );
    },
  );

  test(
    'budget expenses are exact, positive, affordable, and currency specific',
    () {
      final available = BudgetAmount.parse(usd, '35');
      final remaining = available.spend(BudgetAmount.parse(usd, '12.50'));
      expect(remaining.toString(), 'USD 22.50');
      expect(remaining.spend(BudgetAmount.parse(usd, '22.50')).minorUnits, 0);
      expect(available.minorUnits, 3500);
      expect(
        () => available.spend(BudgetAmount(usd, 0)),
        throwsA(isA<InvalidInput>()),
      );
      expect(
        () => available.spend(BudgetAmount(usd, 3501)),
        throwsA(isA<AllowanceExceeded>()),
      );
      expect(
        () => available.spend(BudgetAmount(jpy, 1)),
        throwsA(isA<InvalidInput>()),
      );
      expect(
        () => available + BudgetAmount(jpy, 1),
        throwsA(isA<InvalidInput>()),
      );
      expect(
        () => available - BudgetAmount(jpy, 0),
        throwsA(isA<InvalidInput>()),
      );
      expect(
        () => BudgetAmount.parse(usd, '0.001'),
        throwsA(isA<InvalidInput>()),
      );
      expect(
        () => BudgetAmount.parse(jpy, '1.0'),
        throwsA(isA<InvalidInput>()),
      );
      expect(BudgetAmount.parse(kwd, '0.001').times(3).toString(), 'KWD 0.003');
      expect(
        () => BudgetAmount(usd, maxStoredInteger) + BudgetAmount(usd, 1),
        throwsA(isA<NumericOverflow>()),
      );
      expect(
        () => BudgetAmount(usd, maxStoredInteger).times(2),
        throwsA(isA<NumericOverflow>()),
      );
    },
  );

  test(
    'wallet affordability is available for zero funds and one or both prices',
    () {
      expect(money(0).maximumAffordableQuantity(money(2, 3)), 0);
      expect(money(10, 14).maximumAffordableQuantity(money(2, 3)), 4);
      expect(money(10, 0).maximumAffordableQuantity(money(2, 0)), 5);
      expect(money(0, 14).maximumAffordableQuantity(money(0, 3)), 4);
      expect(
        money(maxStoredInteger).maximumAffordableQuantity(money(1)),
        maxStoredInteger,
      );
      expect(
        () => money(10).maximumAffordableQuantity(money(0)),
        throwsA(isA<InvalidInput>()),
      );
      for (final amounts in [
        (0, 2, true, false),
        (2, 0, false, true),
        (0, 0, true, true),
      ]) {
        expect(
          () => money(amounts.$1, amounts.$2) - money(1, 1),
          throwsA(
            isA<InsufficientFunds>()
                .having((e) => e.coins, 'coins', amounts.$3)
                .having((e) => e.gems, 'gems', amounts.$4),
          ),
        );
      }
      expect((money(2, 3) - money(2, 3)).isZero, isTrue);
      expect(
        () => money(0, maxStoredInteger) + money(0, 1),
        throwsA(isA<NumericOverflow>()),
      );
    },
  );

  test('random wallet maximum buys exactly all affordable whole packs', () {
    final random = Random(812);
    for (var i = 0; i < 500; i++) {
      final price = money(random.nextInt(100), 1 + random.nextInt(100));
      final wallet = money(random.nextInt(10000), random.nextInt(10000));
      final maximum = wallet.maximumAffordableQuantity(price);
      final left = wallet - price.times(maximum);
      expect(left.coins.units, greaterThanOrEqualTo(0));
      expect(left.gems.units, greaterThanOrEqualTo(0));
      expect(
        () => wallet - price.times(maximum + 1),
        throwsA(isA<InsufficientFunds>()),
      );
    }
  });

  test(
    'redemption validates both total grants and leaves inputs untouched',
    () {
      final wallet = money(maxStoredInteger, maxStoredInteger);
      for (final config in [
        AwardConfiguration(
          packName: 'time',
          price: money(1),
          timeGrant: Milliseconds.seconds(maxStoredInteger ~/ 1000),
        ),
        AwardConfiguration(
          packName: 'budget',
          price: money(0, 1),
          budgetGrant: BudgetAmount(usd, maxStoredInteger),
        ),
        AwardConfiguration(
          packName: 'price',
          price: money(0, maxStoredInteger),
          timeGrant: Milliseconds.seconds(1),
        ),
      ]) {
        final result = previewRedemption(
          award: item(config),
          quantity: PurchaseQuantity(2),
          wallet: wallet,
        ) as Failure<RedemptionPreview>;
        expect(result.error, isA<NumericOverflow>());
        expect(wallet.coins.units, maxStoredInteger);
        expect(wallet.gems.units, maxStoredInteger);
      }
      final combined = item(
        AwardConfiguration(
          packName: 'combined',
          price: money(2, 3),
          timeGrant: Milliseconds.seconds(600),
          budgetGrant: BudgetAmount.parse(usd, '12.50'),
        ),
      );
      final preview = (previewRedemption(
        award: combined,
        quantity: PurchaseQuantity(3),
        wallet: money(10, 10),
      ) as Success<RedemptionPreview>).value;
      expect(preview.totalPrice.coins.units, 6);
      expect(preview.totalPrice.gems.units, 9);
      expect(preview.timeGrant, Milliseconds.seconds(1800));
      expect(preview.budgetGrant!.toString(), 'USD 37.50');
      expect(preview.maximumAffordableQuantity, 3);
      expect(preview.walletAfter.coins.units, 4);
      expect(preview.walletAfter.gems.units, 1);
      expect(() => PurchaseQuantity(-1), throwsA(isA<InvalidInput>()));
    },
  );
}
