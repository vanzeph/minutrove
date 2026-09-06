import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/domain/domain.dart';

import '../support/session_fixtures.dart' show SessionCalendar, configuredQuest;

Session initial({DateTime? utc, ReportingZone? zone, int seconds = 900}) {
  final reading = ClockReading(
    utc: utc ?? DateTime.utc(2026, 1, 1),
    bootId: 'initial',
    monotonic: Milliseconds(1000),
  );
  return Session(
    id: SessionId('11111111-1111-4111-8111-111111111111'),
    revision: Revision(1),
    itemSnapshot: configuredQuest(seconds: seconds),
    status: SessionStatus.running,
    zone: zone ?? ReportingZone('Etc/UTC'),
    startedAt: reading,
    checkpoint: reading,
    duration: Milliseconds.seconds(seconds),
    settled: Milliseconds(0),
    deadlineUtc: reading.utc.add(Duration(seconds: seconds)),
    completionId: CompletionId('11111111-1111-4111-8111-111111111111'),
    intervals: const [],
  );
}

/// Synthetic calendar with the known US spring transition: midnight boundaries
/// must come from the port, never a fixed 24-hour addition in session accounting.
class SpringCalendar implements ReportingCalendar {
  @override
  bool supports(ReportingZone zone) => zone.ianaName == 'America/New_York';
  @override
  EventTime assign(DateTime utc, ReportingZone zone) {
    final offset = utc.isBefore(DateTime.utc(2026, 3, 8, 7)) ? -18000 : -14400;
    final local = utc.add(Duration(seconds: offset));
    return EventTime(
      utc: utc,
      day: DayKey(local.year, local.month, local.day),
      zone: zone,
      offsetSeconds: offset,
    );
  }

  @override
  DateTime nextMidnight(EventTime time) {
    final next = DateTime.utc(time.day.year, time.day.month, time.day.day + 1);
    final offset = next.isBefore(DateTime.utc(2026, 3, 9)) ? 5 : 4;
    return next.add(Duration(hours: offset));
  }
}

void main() {
  final calendar = SessionCalendar();
  test('reboot estimates are bounded; backward wall time settles zero and reanchors', () {
    final s = initial(seconds: 60);
    final recovered = advanceSession(
      session: s,
      action: SessionAction.reconcile,
      now: ClockReading(
        utc: s.checkpoint.utc.add(const Duration(days: 1)),
        bootId: 'reboot',
        monotonic: Milliseconds(100),
      ),
      calendar: calendar,
    );
    expect(recovered.session.settled.value, 60000);
    expect(recovered.session.status, SessionStatus.completed);
    expect(recovered.clockDiscontinuity, isTrue);
    final reversed = advanceSession(
      session: s,
      action: SessionAction.reconcile,
      now: ClockReading(
        utc: s.checkpoint.utc.subtract(const Duration(hours: 1)),
        bootId: 'reboot',
        monotonic: Milliseconds(100),
      ),
      calendar: calendar,
    );
    expect(reversed.session.settled.value, 0);
    expect(reversed.addedIntervals, isEmpty);
    expect(
      reversed.session.deadlineUtc,
      reversed.session.checkpoint.utc.add(const Duration(seconds: 60)),
    );
    expect(reversed.clockDiscontinuity, isTrue);
    final next = advanceSession(
      session: reversed.session,
      action: SessionAction.end,
      now: ClockReading(
        utc: reversed.session.checkpoint.utc.add(const Duration(seconds: 1)),
        bootId: 'reboot',
        monotonic: Milliseconds(1100),
      ),
      calendar: calendar,
    );
    expect(next.session.settled.value, 1000);
  });

  test(
    'same boot ignores forward wall jumps and refuses monotonic reversal',
    () {
      final s = initial();
      final projected = advanceSession(
        session: s,
        action: SessionAction.reconcile,
        now: ClockReading(
          utc: s.checkpoint.utc.add(const Duration(days: 1)),
          bootId: 'initial',
          monotonic: Milliseconds(2000),
        ),
        calendar: calendar,
      );
      expect(projected.session.settled.value, 1000);
      expect(projected.clockDiscontinuity, isTrue);
      expect(
        projected.session.deadlineUtc,
        projected.session.checkpoint.utc.add(
          const Duration(milliseconds: 899000),
        ),
      );
      expect(
        () => advanceSession(
          session: s,
          action: SessionAction.reconcile,
          now: ClockReading(
            utc: s.checkpoint.utc,
            bootId: 'initial',
            monotonic: Milliseconds(999),
          ),
          calendar: calendar,
        ),
        throwsA(isA<InvalidInput>()),
      );
    },
  );

  test('calendar midnight splits a 23-hour day without losing or repeating active time', () {
    final s = initial(
      utc: DateTime.utc(2026, 3, 7, 5),
      zone: ReportingZone('America/New_York'),
      seconds: 172800,
    );
    final p = advanceSession(
      session: s,
      action: SessionAction.reconcile,
      now: ClockReading(
        utc: DateTime.utc(2026, 3, 9, 5),
        bootId: 'initial',
        monotonic: Milliseconds(172801000),
      ),
      calendar: SpringCalendar(),
    );
    expect(p.session.status, SessionStatus.completed);
    expect(p.addedIntervals.map((i) => i.active.value), [
      86400000,
      82800000,
      3600000,
    ]);
    expect(p.addedIntervals.map((i) => i.assignment.day), [
      DayKey(2026, 3, 7),
      DayKey(2026, 3, 8),
      DayKey(2026, 3, 9),
    ]);
    expect(
      p.addedIntervals.fold(0, (int value, i) => value + i.active.value),
      172800000,
    );
    expect(s.settled.value, 0);
    expect(s.intervals, isEmpty);
  });

  test('oversized deadline is a typed failure', () {
    expect(
      () => sessionDeadline(DateTime.utc(2026), Milliseconds(maxStoredInteger)),
      throwsA(isA<NumericOverflow>()),
    );
  });
}
