import 'package:minutrove/domain/domain.dart';

class SessionClock implements Clock {
  DateTime utc = DateTime.utc(2026, 1, 15, 12);
  int monotonic = 1000;
  String boot = 'session-test';
  bool unavailable = false;
  void advance(int milliseconds) {
    utc = utc.add(Duration(milliseconds: milliseconds));
    monotonic += milliseconds;
  }

  @override
  ClockReading now() {
    if (unavailable) throw StateError('Replay must not read the clock');
    return ClockReading(
      utc: utc,
      bootId: boot,
      monotonic: Milliseconds(monotonic),
    );
  }
}

class SessionCalendar implements ReportingCalendar {
  @override
  bool supports(ReportingZone zone) => zone.ianaName == 'Etc/UTC';
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

Item configuredQuest({
  int id = 1,
  int seconds = 900,
  int coins = 120000000,
  int gems = 2400000,
  int revision = 1,
  bool archived = false,
}) => Item(
  id: ItemId('00000000-0000-4000-8000-${id.toString().padLeft(12, '0')}'),
  revision: Revision(revision),
  name: 'Synthetic Quest',
  iconKey: 'gamepad',
  colorArgb: 0xff883366,
  groupId: null,
  order: 0,
  archived: archived,
  configuration: QuestConfiguration(
    duration: Milliseconds.seconds(seconds),
    ratesPerHour: CurrencyAmounts(
      coins: MicroAmount(coins),
      gems: MicroAmount(gems),
    ),
  ),
);
