import 'result.dart';

/// The durable integer boundary (SQLite signed 64-bit); calculate before narrowing.
const maxStoredInteger = 0x7fffffffffffffff;

int checkedInteger(
  BigInt value, {
  String field = 'amount',
  bool signed = false,
}) {
  final max = BigInt.from(maxStoredInteger);
  if (value > max || value < (signed ? -max - BigInt.one : BigInt.zero)) {
    throw NumericOverflow(field);
  }
  return value.toInt();
}

int nonNegative(int value, String field) {
  if (value < 0) throw InvalidInput(field, 'Must be non-negative');
  return value;
}

String nonEmpty(String value, String field) {
  if (value.trim().isEmpty) throw InvalidInput(field, 'Must not be empty');
  return value;
}

final class ItemTag {}

final class GroupTag {}

final class SessionTag {}

final class OperationTag {}

final class LedgerTag {}

final class CompletionTag {}

/// Canonical UUID syntax; separate generic tags prevent mixing entity identities.
final class Id<T> {
  factory Id(String value) {
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(value)) {
      throw const InvalidInput('id', 'Expected UUID');
    }
    return Id._(value.toLowerCase());
  }
  const Id._(this.value);
  final String value;
  @override
  bool operator ==(Object other) => other is Id<T> && value == other.value;
  @override
  int get hashCode => Object.hash(T, value);
  @override
  String toString() => value;
}

typedef ItemId = Id<ItemTag>;
typedef GroupId = Id<GroupTag>;
typedef SessionId = Id<SessionTag>;
typedef OperationId = Id<OperationTag>;
typedef LedgerId = Id<LedgerTag>;
typedef CompletionId = Id<CompletionTag>;

final class Revision {
  Revision(int value) : value = nonNegative(value, 'revision') {
    if (value == 0) throw const InvalidInput('revision', 'Must be positive');
  }
  final int value;
  Revision next() => Revision(checkedInteger(BigInt.from(value) + BigInt.one));
  @override
  bool operator ==(Object other) => other is Revision && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

int _parseScaled(String input, int decimals) =>
    checkedInteger(_parseScaledBig(input, decimals));

BigInt _parseScaledBig(String input, int decimals) {
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(input)) {
    throw const InvalidInput('amount', 'Expected unsigned plain decimal');
  }
  final parts = input.split('.');
  final fraction = parts.length == 2 ? parts[1] : '';
  if (fraction.length > decimals) {
    throw const InvalidInput('amount', 'Too many decimal places');
  }
  return BigInt.parse(parts[0]) * BigInt.from(10).pow(decimals) +
      (fraction.isEmpty
          ? BigInt.zero
          : BigInt.parse(fraction.padRight(decimals, '0')));
}

String _formatScaled(int value, int decimals) {
  if (decimals == 0) return '$value';
  final digits = value.toString().padLeft(decimals + 1, '0');
  return '${digits.substring(0, digits.length - decimals)}.${digits.substring(digits.length - decimals)}';
}

/// Non-negative currency millionths. Parsing never goes through a double.
final class MicroAmount {
  MicroAmount(int units) : units = nonNegative(units, 'millionths');
  factory MicroAmount.parse(String input) =>
      MicroAmount(_parseScaled(input, 6));
  final int units;
  MicroAmount operator +(MicroAmount other) => MicroAmount(
    checkedInteger(BigInt.from(units) + BigInt.from(other.units)),
  );
  MicroAmount operator -(MicroAmount other) {
    if (other.units > units) throw const AllowanceExceeded();
    return MicroAmount(units - other.units);
  }

  MicroAmount times(int quantity) => MicroAmount(
    checkedInteger(
      BigInt.from(units) * BigInt.from(nonNegative(quantity, 'quantity')),
    ),
  );
  @override
  String toString() => _formatScaled(units, 6);
  @override
  bool operator ==(Object other) =>
      other is MicroAmount && units == other.units;
  @override
  int get hashCode => units.hashCode;
}

/// Editor units; durable durations remain integer milliseconds.
enum TimeUnit {
  seconds(1000),
  minutes(60000),
  hours(3600000);

  const TimeUnit(this.milliseconds);
  final int milliseconds;
}

/// Parse a six-decimal rate and normalize without rounding.
/// A zero component is valid; QuestConfiguration rejects two zero rates.
MicroAmount normalizeRatePerHour(String input, {required TimeUnit per}) =>
    MicroAmount.parse(input).times(3600000 ~/ per.milliseconds);

final class Milliseconds {
  Milliseconds(int value) : value = nonNegative(value, 'milliseconds');
  factory Milliseconds.seconds(int seconds) => Milliseconds(
    checkedInteger(
      BigInt.from(nonNegative(seconds, 'seconds')) * BigInt.from(1000),
    ),
  );

  /// Editors may show fractions of minutes/hours, but configuration must
  /// resolve to positive whole seconds. No fractional second is rounded away.
  factory Milliseconds.parseConfiguration(
    String input, {
    required TimeUnit unit,
  }) {
    final scaled = _parseScaledBig(input, 6);
    final secondsNumerator = scaled * BigInt.from(unit.milliseconds ~/ 1000);
    final scale = BigInt.from(1000000);
    if (secondsNumerator == BigInt.zero ||
        secondsNumerator % scale != BigInt.zero) {
      throw const InvalidInput('duration', 'Expected positive whole seconds');
    }
    return Milliseconds(
      checkedInteger(secondsNumerator ~/ scale * BigInt.from(1000)),
    );
  }
  final int value;
  Milliseconds operator +(Milliseconds other) => Milliseconds(
    checkedInteger(BigInt.from(value) + BigInt.from(other.value)),
  );
  Milliseconds operator -(Milliseconds other) {
    if (other.value > value) throw const AllowanceExceeded();
    return Milliseconds(value - other.value);
  }

  /// Only active elapsed time is supplied. Overshoot consumes the remainder.
  ({Milliseconds consumed, Milliseconds remaining}) consume(
    Milliseconds active,
  ) {
    final consumed = active.value < value ? active : this;
    return (consumed: consumed, remaining: this - consumed);
  }

  Milliseconds times(int quantity) => Milliseconds(
    checkedInteger(
      BigInt.from(value) * BigInt.from(nonNegative(quantity, 'quantity')),
    ),
  );
  @override
  bool operator ==(Object other) =>
      other is Milliseconds && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

/// Persist a remainder for each Quest/currency; never discard it on early end.
final class AccrualRemainder {
  AccrualRemainder(this.value) {
    if (value < 0 || value >= 3600000) {
      throw const InvalidInput('remainder', 'Outside division range');
    }
  }
  final int value;
}

typedef AccruedAmount = ({MicroAmount amount, AccrualRemainder remainder});

AccruedAmount accrue({
  required MicroAmount perHour,
  required Milliseconds active,
  required AccrualRemainder remainder,
}) {
  final numerator =
      BigInt.from(perHour.units) * BigInt.from(active.value) +
      BigInt.from(remainder.value);
  final divisor = BigInt.from(3600000);
  return (
    amount: MicroAmount(checkedInteger(numerator ~/ divisor)),
    remainder: AccrualRemainder((numerator % divisor).toInt()),
  );
}

/// An adapter supplies pinned ISO currency metadata; no exchange-rate dependency.
abstract interface class CurrencyMetadata {
  String get version;
  int? minorDigitsFor(String isoCode);
}

final class BudgetCurrency {
  factory BudgetCurrency.fromMetadata(String code, CurrencyMetadata metadata) {
    final digits = metadata.minorDigitsFor(code);
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(code) ||
        digits == null ||
        digits < 0 ||
        digits > 4 ||
        metadata.version.isEmpty) {
      throw const InvalidInput('currency', 'Unsupported pinned ISO currency');
    }
    return BudgetCurrency._(code, digits);
  }
  const BudgetCurrency._(this.code, this.minorDigits);
  final String code;
  final int minorDigits;
  @override
  bool operator ==(Object other) =>
      other is BudgetCurrency &&
      code == other.code &&
      minorDigits == other.minorDigits;
  @override
  int get hashCode => Object.hash(code, minorDigits);
}

final class BudgetAmount {
  BudgetAmount(this.currency, int minorUnits)
    : minorUnits = nonNegative(minorUnits, 'minorUnits');
  factory BudgetAmount.parse(BudgetCurrency currency, String input) =>
      BudgetAmount(currency, _parseScaled(input, currency.minorDigits));
  final BudgetCurrency currency;
  final int minorUnits;
  BudgetAmount times(int quantity) => BudgetAmount(
    currency,
    checkedInteger(
      BigInt.from(minorUnits) * BigInt.from(nonNegative(quantity, 'quantity')),
    ),
  );
  BudgetAmount operator +(BudgetAmount other) {
    if (currency != other.currency) {
      throw const InvalidInput('currency', 'Unlike currencies');
    }
    return BudgetAmount(
      currency,
      checkedInteger(BigInt.from(minorUnits) + BigInt.from(other.minorUnits)),
    );
  }

  BudgetAmount operator -(BudgetAmount other) {
    if (currency != other.currency) {
      throw const InvalidInput('currency', 'Unlike currencies');
    }
    if (other.minorUnits > minorUnits) throw const AllowanceExceeded();
    return BudgetAmount(currency, minorUnits - other.minorUnits);
  }

  /// Expenses are positive; subtraction itself also supports zero balances.
  BudgetAmount spend(BudgetAmount expense) {
    if (expense.minorUnits == 0) {
      throw const InvalidInput('expense', 'Must be positive');
    }
    return this - expense;
  }

  @override
  String toString() =>
      '${currency.code} ${_formatScaled(minorUnits, currency.minorDigits)}';
}

final class CurrencyAmounts {
  const CurrencyAmounts({required this.coins, required this.gems});
  final MicroAmount coins;
  final MicroAmount gems;
  bool get isZero => coins.units == 0 && gems.units == 0;
  CurrencyAmounts operator +(CurrencyAmounts other) =>
      CurrencyAmounts(coins: coins + other.coins, gems: gems + other.gems);
  CurrencyAmounts operator -(CurrencyAmounts other) {
    final coinsShort = coins.units < other.coins.units;
    final gemsShort = gems.units < other.gems.units;
    if (coinsShort || gemsShort) {
      throw InsufficientFunds(coins: coinsShort, gems: gemsShort);
    }
    return CurrencyAmounts(coins: coins - other.coins, gems: gems - other.gems);
  }

  /// Wallet affordability only; callers must also check grant and pooled
  /// allowance overflow for a requested purchase. Zero-price dimensions do
  /// not constrain quantity, but a completely free pack is invalid.
  int maximumAffordableQuantity(CurrencyAmounts price) {
    if (price.isZero) {
      throw const InvalidInput('price', 'At least one price must be positive');
    }
    var maximum = maxStoredInteger;
    for (final pair in [(coins, price.coins), (gems, price.gems)]) {
      if (pair.$2.units != 0) {
        final affordable = pair.$1.units ~/ pair.$2.units;
        if (affordable < maximum) maximum = affordable;
      }
    }
    return maximum;
  }

  CurrencyAmounts times(int quantity) =>
      CurrencyAmounts(coins: coins.times(quantity), gems: gems.times(quantity));
}

/// Keep both results with the same Quest across checkpoints and sessions.
/// Persist the returned remainders even when neither currency earns a unit.
typedef CurrencyAccrualRemainders = ({
  AccrualRemainder coins,
  AccrualRemainder gems,
});
typedef AccruedCurrencies = ({
  CurrencyAmounts amounts,
  CurrencyAccrualRemainders remainders,
});

AccruedCurrencies accrueCurrencies({
  required CurrencyAmounts ratesPerHour,
  required Milliseconds active,
  required CurrencyAccrualRemainders remainders,
}) {
  final coins = accrue(
    perHour: ratesPerHour.coins,
    active: active,
    remainder: remainders.coins,
  );
  final gems = accrue(
    perHour: ratesPerHour.gems,
    active: active,
    remainder: remainders.gems,
  );
  return (
    amounts: CurrencyAmounts(coins: coins.amount, gems: gems.amount),
    remainders: (coins: coins.remainder, gems: gems.remainder),
  );
}

/// Frozen calendar assignment; the timezone adapter validates IANA membership.
final class DayKey {
  DayKey(this.year, this.month, this.day) {
    if (year < 1 ||
        year > 9999 ||
        month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31) {
      throw const InvalidInput('day', 'Invalid calendar date');
    }
    final date = DateTime.utc(year, month, day);
    if (year < 1 ||
        year > 9999 ||
        date.year != year ||
        date.month != month ||
        date.day != day) {
      throw const InvalidInput('day', 'Invalid calendar date');
    }
  }
  final int year;
  final int month;
  final int day;
  @override
  bool operator ==(Object other) =>
      other is DayKey &&
      year == other.year &&
      month == other.month &&
      day == other.day;
  @override
  int get hashCode => Object.hash(year, month, day);
}

final class ReportingZone {
  ReportingZone(String ianaName) : ianaName = nonEmpty(ianaName, 'timezone');
  final String ianaName;
}

final class EventTime {
  EventTime({
    required this.utc,
    required this.day,
    required this.zone,
    required this.offsetSeconds,
  }) {
    if (!utc.isUtc || (offsetSeconds < -86400 || offsetSeconds > 86400)) {
      throw const InvalidInput('eventTime', 'Expected UTC and valid offset');
    }
    final local = utc.add(Duration(seconds: offsetSeconds));
    if (day != DayKey(local.year, local.month, local.day)) {
      throw const InvalidInput('eventTime', 'Day and offset disagree');
    }
  }
  final DateTime utc;
  final DayKey day;
  final ReportingZone zone;
  final int offsetSeconds;
}
