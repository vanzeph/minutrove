import 'package:timezone/data/latest_all.dart' as data;
import 'package:timezone/timezone.dart' as tz;

import '../domain/domain.dart';

/// Offline IANA rules from the locked timezone package (full history database).
/// No device-local timezone or network lookup participates in attribution.
final class IanaReportingCalendar implements ReportingCalendar {
  static final Map<String, tz.Location> _locations = _load();

  static Map<String, tz.Location> _load() {
    data.initializeTimeZones();
    return Map.unmodifiable(tz.timeZoneDatabase.locations);
  }

  @override
  bool supports(ReportingZone zone) => _locations.containsKey(zone.ianaName);

  tz.Location _location(ReportingZone zone) =>
      _locations[zone.ianaName] ??
      (throw const InvalidInput('reportingZone', 'Unsupported IANA zone'));

  @override
  EventTime assign(DateTime utc, ReportingZone zone) {
    if (!utc.isUtc) throw const InvalidInput('clock', 'Expected UTC time');
    final offset = _location(zone).timeZone(utc.millisecondsSinceEpoch).offset;
    final local = utc.add(offset);
    return EventTime(
      utc: utc,
      day: DayKey(local.year, local.month, local.day),
      zone: zone,
      offsetSeconds: offset.inSeconds,
    );
  }

  @override
  DateTime nextMidnight(EventTime time) {
    final location = _location(time.zone);
    final day = assign(time.utc, time.zone).day;
    var cursor = time.utc.millisecondsSinceEpoch;
    // Walk offset spans rather than adding 24 hours or constructing a possibly
    // missing/ambiguous local midnight. A jump can skip an entire calendar date.
    while (true) {
      final span = location.lookupTimeZone(cursor);
      final local = DateTime.fromMillisecondsSinceEpoch(
        cursor + span.timeZone.offset.inMilliseconds,
        isUtc: true,
      );
      final midnight =
          DateTime.utc(
            local.year,
            local.month,
            local.day + 1,
          ).millisecondsSinceEpoch -
          span.timeZone.offset.inMilliseconds;
      if (midnight < span.end) {
        return DateTime.fromMillisecondsSinceEpoch(midnight, isUtc: true);
      }
      cursor = span.end;
      final boundary = DateTime.fromMillisecondsSinceEpoch(cursor, isUtc: true);
      if (assign(boundary, time.zone).day != day) return boundary;
    }
  }
}
