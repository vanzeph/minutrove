import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';

void main() {
  final calendar = IanaReportingCalendar();

  test(
    'validates IANA membership and preserves UTC, date and second offset',
    () {
      final zone = ReportingZone('Asia/Kathmandu');
      final utc = DateTime.utc(2026, 3, 7, 19);
      final assigned = calendar.assign(utc, zone);
      expect(assigned.utc, utc);
      expect(assigned.zone.ianaName, 'Asia/Kathmandu');
      expect(assigned.day, DayKey(2026, 3, 8));
      expect(assigned.offsetSeconds, 20700);
      expect(calendar.supports(ReportingZone('Mars/Olympus')), isFalse);
      expect(
        () => calendar.assign(utc, ReportingZone('UTC+5')),
        throwsA(isA<InvalidInput>()),
      );
      expect(
        () => calendar.assign(DateTime(2026), zone),
        throwsA(isA<InvalidInput>()),
      );
    },
  );

  for (final sample in [
    (
      'America/Los_Angeles',
      '2026-03-08T08:00:00Z',
      '2026-03-09T07:00:00Z',
      23.0,
    ),
    (
      'America/Los_Angeles',
      '2026-11-01T07:00:00Z',
      '2026-11-02T08:00:00Z',
      25.0,
    ),
    (
      'Australia/Lord_Howe',
      '2026-10-03T13:30:00Z',
      '2026-10-04T13:00:00Z',
      23.5,
    ),
    (
      'Australia/Lord_Howe',
      '2026-04-04T13:00:00Z',
      '2026-04-05T13:30:00Z',
      24.5,
    ),
    ('America/Havana', '2026-11-01T04:00:00Z', '2026-11-02T05:00:00Z', 25.0),
    ('America/Sao_Paulo', '2018-11-03T03:00:00Z', '2018-11-04T03:00:00Z', 24.0),
    ('Pacific/Apia', '2011-12-29T10:00:00Z', '2011-12-30T10:00:00Z', 24.0),
  ]) {
    test(
      '${sample.$1}: midnight from ${sample.$2} spans ${sample.$4} hours',
      () {
        final zone = ReportingZone(sample.$1);
        final start = calendar.assign(DateTime.parse(sample.$2), zone);
        final end = calendar.nextMidnight(start);
        expect(end, DateTime.parse(sample.$3));
        expect(end.difference(start.utc).inMinutes, (sample.$4 * 60).toInt());
        expect(calendar.assign(end, zone).day, isNot(start.day));
        expect(
          calendar
              .assign(end.subtract(const Duration(milliseconds: 1)), zone)
              .day,
          start.day,
        );
        expect(
          calendar.nextMidnight(calendar.assign(end, zone)).isAfter(end),
          isTrue,
        );
      },
    );
  }

  test(
    'skipped dates and nonexistent midnight use the first actual next date',
    () {
      final apia = ReportingZone('Pacific/Apia');
      final next = calendar.nextMidnight(
        calendar.assign(DateTime.utc(2011, 12, 30, 9), apia),
      );
      expect(calendar.assign(next, apia).day, DayKey(2011, 12, 31));
      final brazil = ReportingZone('America/Sao_Paulo');
      final boundary = calendar.nextMidnight(
        calendar.assign(DateTime.utc(2018, 11, 4, 2, 30), brazil),
      );
      final local = boundary.add(
        Duration(seconds: calendar.assign(boundary, brazil).offsetSeconds),
      );
      expect(local.hour, 1);
    },
  );

  test(
    'both repeated fall-back hours share a date and retain different offsets',
    () {
      final zone = ReportingZone('America/Los_Angeles');
      final first = calendar.assign(DateTime.utc(2026, 11, 1, 8, 30), zone);
      final second = calendar.assign(DateTime.utc(2026, 11, 1, 9, 30), zone);
      expect(first.day, second.day);
      expect(first.offsetSeconds, -7 * 3600);
      expect(second.offsetSeconds, -8 * 3600);
      expect(calendar.nextMidnight(first), calendar.nextMidnight(second));
    },
  );
}
