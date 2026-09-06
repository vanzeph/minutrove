// Run with `dart run test/domain/standalone_smoke.dart`, without Flutter runtime.
import 'package:minutrove/domain/domain.dart';

final class ClockFixture implements Clock {
  @override
  ClockReading now() => ClockReading(
    utc: DateTime.utc(2026),
    bootId: 'synthetic-boot',
    monotonic: Milliseconds(0),
  );
}

void main() {
  final Clock clock = ClockFixture();
  final result = accrue(
    perHour: MicroAmount.parse('120'),
    active: Milliseconds.seconds(300),
    remainder: AccrualRemainder(0),
  );
  if (!clock.now().utc.isUtc || result.amount != MicroAmount.parse('10')) {
    throw StateError('Standalone domain contract failed');
  }
}
