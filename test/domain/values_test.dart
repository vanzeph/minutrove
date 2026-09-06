import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/domain/domain.dart';

final class TestCurrencies implements CurrencyMetadata {
  @override
  String get version => 'synthetic-fixture-1';
  @override
  int? minorDigitsFor(String code) => {'USD': 2, 'JPY': 0, 'KWD': 3}[code];
}

void main() {
  test('UUID tags stay distinct and canonicalize casing', () {
    final id = ItemId('ABCDEF00-0000-0000-0000-000000000001');
    expect(id, ItemId('abcdef00-0000-0000-0000-000000000001'));
    expect(id, isNot(OperationId(id.value)));
    expect(() => ItemId('invalid'), throwsA(isA<InvalidInput>()));
    expect(() => Revision(0), throwsA(isA<InvalidInput>()));
    expect(
      () => Revision(maxStoredInteger).next(),
      throwsA(isA<NumericOverflow>()),
    );
  });

  test('six-digit decimal parsing is exact through signed 64-bit maximum', () {
    expect(MicroAmount.parse('9223372036854.775807').units, maxStoredInteger);
    expect(MicroAmount.parse('0.000001').units, 1);
    expect(MicroAmount.parse('12.5').toString(), '12.500000');
    expect(
      () => MicroAmount.parse('9223372036854.775808'),
      throwsA(isA<NumericOverflow>()),
    );
  });

  for (final input in [
    'NaN',
    'Infinity',
    '-1',
    '1e6',
    '1.0000001',
    '',
    ' 1',
    '1.',
    '.1',
    '+1',
  ]) {
    test('rejects invalid numeric input $input', () {
      expect(() => MicroAmount.parse(input), throwsA(isA<InvalidInput>()));
    });
  }

  test('checked arithmetic rejects overflow and negative amounts', () {
    expect(() => MicroAmount(-1), throwsA(isA<InvalidInput>()));
    expect(
      () => MicroAmount(maxStoredInteger) + MicroAmount(1),
      throwsA(isA<NumericOverflow>()),
    );
    expect(
      () => MicroAmount(maxStoredInteger).times(2),
      throwsA(isA<NumericOverflow>()),
    );
    expect(
      () => Milliseconds.seconds(maxStoredInteger),
      throwsA(isA<NumericOverflow>()),
    );
    expect(
      () => MicroAmount(0) - MicroAmount(1),
      throwsA(isA<AllowanceExceeded>()),
    );
  });

  test(
    'early end credits exact example and split sessions retain remainder',
    () {
      final rate = MicroAmount.parse('120');
      expect(
        accrue(
          perHour: rate,
          active: Milliseconds.seconds(300),
          remainder: AccrualRemainder(0),
        ).amount,
        MicroAmount.parse('10'),
      );
      var remainder = AccrualRemainder(0);
      var units = 0;
      for (var i = 0; i < 1001; i++) {
        final result = accrue(
          perHour: MicroAmount(7),
          active: Milliseconds(3599),
          remainder: remainder,
        );
        units += result.amount.units;
        remainder = result.remainder;
      }
      final whole = accrue(
        perHour: MicroAmount(7),
        active: Milliseconds(3599 * 1001),
        remainder: AccrualRemainder(0),
      );
      expect(units, whole.amount.units);
      expect(remainder.value, whole.remainder.value);
    },
  );

  test('large intermediate products are safe; only final overflow rejects', () {
    expect(
      accrue(
        perHour: MicroAmount(maxStoredInteger),
        active: Milliseconds(3600000),
        remainder: AccrualRemainder(0),
      ).amount.units,
      maxStoredInteger,
    );
    expect(
      () => accrue(
        perHour: MicroAmount(maxStoredInteger),
        active: Milliseconds(7200000),
        remainder: AccrualRemainder(0),
      ),
      throwsA(isA<NumericOverflow>()),
    );
    expect(() => AccrualRemainder(3600000), throwsA(isA<InvalidInput>()));
    final paused = accrue(
      perHour: MicroAmount(10),
      active: Milliseconds(0),
      remainder: AccrualRemainder(9),
    );
    expect(paused.amount.units, 0);
    expect(paused.remainder.value, 9);
  });

  test(
    'budget precision comes from pinned metadata; currencies cannot combine',
    () {
      final usd = BudgetCurrency.fromMetadata('USD', TestCurrencies());
      final jpy = BudgetCurrency.fromMetadata('JPY', TestCurrencies());
      final kwd = BudgetCurrency.fromMetadata('KWD', TestCurrencies());
      expect(BudgetAmount.parse(usd, '12.50').minorUnits, 1250);
      expect(BudgetAmount.parse(kwd, '0.001').minorUnits, 1);
      expect(
        () => BudgetAmount.parse(jpy, '1.1'),
        throwsA(isA<InvalidInput>()),
      );
      expect(
        () => BudgetCurrency.fromMetadata('XYZ', TestCurrencies()),
        throwsA(isA<InvalidInput>()),
      );
      expect(
        () => BudgetAmount(usd, 1) + BudgetAmount(jpy, 1),
        throwsA(isA<InvalidInput>()),
      );
    },
  );

  test(
    'frozen calendar assignments reject normalized or contradictory dates',
    () {
      expect(
        () => DayKey(maxStoredInteger, 1, 1),
        throwsA(isA<InvalidInput>()),
      );
      expect(() => DayKey(2025, 2, 29), throwsA(isA<InvalidInput>()));
      expect(DayKey(2024, 2, 29), DayKey(2024, 2, 29));
      final utc = DateTime.utc(2026, 1, 2, 1);
      final time = EventTime(
        utc: utc,
        day: DayKey(2026, 1, 1),
        zone: ReportingZone('America/Los_Angeles'),
        offsetSeconds: -28800,
      );
      expect(time.day.day, 1);
      expect(
        () => EventTime(
          utc: utc,
          day: DayKey(2026, 1, 2),
          zone: time.zone,
          offsetSeconds: -28800,
        ),
        throwsA(isA<InvalidInput>()),
      );
    },
  );
}
