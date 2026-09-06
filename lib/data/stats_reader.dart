import 'package:sqflite_common/sqlite_api.dart';
import 'package:timezone/timezone.dart' as tz;

import '../domain/domain.dart';
import 'reporting_calendar.dart';

/// Calendar labels use UTC containers, not physical instants in the current
/// settings zone. This preserves dates across travel and prospective zone edits.
/// Daily charts have 24 civil-hour labels: repeated hours combine, gaps stay zero.
Future<List<StatsBucket>> readStatistics(
  DatabaseExecutor db,
  StatsQuery query,
) async {
  final a = query.anchor;
  final anchor = DateTime.utc(a.year, a.month, a.day);
  final start = switch (query.period) {
    StatsPeriod.daily || StatsPeriod.monthly => DateTime.utc(
      a.year,
      a.month,
      query.period == StatsPeriod.daily ? a.day : 1,
    ),
    StatsPeriod.weekly => anchor.subtract(Duration(days: anchor.weekday - 1)),
    StatsPeriod.yearly => DateTime.utc(a.year),
  };
  final end = switch (query.period) {
    StatsPeriod.daily => start.add(const Duration(days: 1)),
    StatsPeriod.weekly => start.add(const Duration(days: 7)),
    StatsPeriod.monthly => DateTime.utc(a.year, a.month + 1),
    StatsPeriod.yearly => DateTime.utc(a.year + 1),
  };
  final boundaries = <DateTime>[start];
  while (boundaries.last.isBefore(end)) {
    final last = boundaries.last;
    boundaries.add(switch (query.period) {
      StatsPeriod.daily => last.add(const Duration(hours: 1)),
      StatsPeriod.weekly ||
      StatsPeriod.monthly => last.add(const Duration(days: 1)),
      StatsPeriod.yearly => DateTime.utc(last.year, last.month + 1),
    });
  }
  final values = List.filled(boundaries.length - 1, BigInt.zero);
  final goal = query.metric == StatsMetric.dailyGoalCompletion;
  final time =
      query.metric == StatsMetric.questTime ||
      query.metric == StatsMetric.awardTime;
  final table = goal ? 'daily_achievements' : 'ledger_entries';
  final day = goal ? 'day' : 'assigned_day';
  final utc = goal ? 'awarded_utc' : 'assigned_utc';
  final offset = goal ? 'awarded_offset' : 'assigned_offset';
  final item = goal ? 'quest_id' : 'item_id';
  final where = <String>['e.$day >= ?', 'e.$day <= ?'];
  final args = <Object?>[
    _date(start),
    _date(end.subtract(const Duration(days: 1))),
  ];
  if (query.itemId != null) {
    where.add('e.$item = ?');
    args.add(query.itemId!.value);
  }
  if (!goal) {
    final (dimension, positive, type) = switch (query.metric) {
      StatsMetric.questTime => ('time', true, 'quest'),
      StatsMetric.awardTime => ('time', false, 'award'),
      StatsMetric.budgetSpent => ('budget', false, 'award'),
      StatsMetric.coinsEarned => ('coins', true, 'quest'),
      StatsMetric.coinsSpent => ('coins', false, 'award'),
      StatsMetric.gemsEarned => ('gems', true, 'quest'),
      StatsMetric.gemsSpent => ('gems', false, 'award'),
      StatsMetric.dailyGoalCompletion => throw StateError('Handled above'),
    };
    where.addAll([
      'e.dimension = ?',
      positive ? 'e.delta > 0' : 'e.delta < 0',
      'r.type = ?',
    ]);
    args.addAll([dimension, type]);
    if (query.budgetCurrency case final currency?) {
      where.addAll(['e.budget_currency = ?', 'e.budget_digits = ?']);
      args.addAll([currency.code, currency.minorDigits]);
    }
  }
  final from =
      '$table e${goal ? '' : ' JOIN item_revisions r ON '
                'r.item_id = e.item_id AND r.revision = e.item_revision'}';
  final predicate = where.join(' AND ');
  if (time && query.period == StatsPeriod.daily) {
    // Time postings are settled intervals, not point events. Read only this day
    // in fixed pages and split at both civil hours and actual offset changes.
    // Currency postings remain point events with their frozen event assignment.
    var cursor = 0;
    while (true) {
      final rows = await db.rawQuery(
        'SELECT e.rowid AS cursor, e.assigned_utc, e.assigned_zone, '
        'e.assigned_offset, e.delta FROM $from WHERE $predicate '
        'AND e.rowid > ? ORDER BY e.rowid LIMIT 512',
        [...args, cursor],
      );
      for (final row in rows) {
        cursor = row['cursor'] as int;
        _allocateTime(row, values);
      }
      if (rows.length < 512) break;
    }
  } else {
    final bucket = switch (query.period) {
      StatsPeriod.daily =>
        // Integer arithmetic preserves millisecond precision before the epoch.
        '(((e.$utc % 86400000 + e.$offset * 1000) % 86400000 '
            '+ 86400000) % 86400000) / 3600000',
      StatsPeriod.weekly || StatsPeriod.monthly => 'e.$day',
      StatsPeriod.yearly => 'substr(e.$day, 1, 7)',
    };
    // Split integers before SUM so totals near int64 remain exact, even when
    // their combined magnitude exceeds int64. Never use SQLite TOTAL/REAL.
    final aggregate = goal
        ? 'COUNT(*) AS high, 0 AS low'
        : 'SUM(e.delta / 4294967296) AS high, '
              'SUM(e.delta % 4294967296) AS low';
    final rows = await db.rawQuery(
      'SELECT $bucket AS bucket, $aggregate FROM $from '
      'WHERE $predicate GROUP BY bucket',
      args,
    );
    final indices = <String, int>{
      for (var i = 0; i < values.length; i++)
        (query.period == StatsPeriod.yearly
                ? _date(boundaries[i]).substring(0, 7)
                : _date(boundaries[i])):
            i,
    };
    for (final row in rows) {
      final index = query.period == StatsPeriod.daily
          ? row['bucket'] as int
          : indices[row['bucket']]!;
      final high = BigInt.from(row['high'] as int);
      values[index] = goal
          ? high
          : (high * BigInt.from(4294967296) + BigInt.from(row['low'] as int))
                .abs();
    }
  }
  return List.unmodifiable([
    for (var i = 0; i < values.length; i++)
      StatsBucket(
        start: boundaries[i],
        end: boundaries[i + 1],
        value: checkedInteger(values[i], field: 'statistics'),
      ),
  ]);
}

String _date(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

void _allocateTime(Map<String, Object?> row, List<BigInt> values) {
  final zone = ReportingZone(row['assigned_zone'] as String);
  // supports also initializes the pinned database when Stats is the first
  // adapter used after opening an existing file. Construction alone is lazy.
  if (!IanaReportingCalendar().supports(zone)) {
    throw const FormatException('Unknown historical reporting zone');
  }
  final location = tz.getLocation(zone.ianaName);
  var cursor = row['assigned_utc'] as int;
  var remaining = BigInt.from(row['delta'] as int).abs();
  // Valid settlement splits at midnight. Bound work for corrupt/imported rows
  // too; no IANA civil date can span more than this conservative three days.
  if (remaining > BigInt.from(3 * 86400000)) {
    throw const FormatException('Time posting exceeds a calendar day');
  }
  var offset = (row['assigned_offset'] as int) * 1000;
  while (remaining > BigInt.zero) {
    final local = DateTime.fromMillisecondsSinceEpoch(
      cursor + offset,
      isUtc: true,
    );
    final nextHour =
        DateTime.utc(
          local.year,
          local.month,
          local.day,
          local.hour + 1,
        ).millisecondsSinceEpoch -
        offset;
    final span = location.lookupTimeZone(cursor);
    final boundary = nextHour < span.end ? nextHour : span.end;
    final available = BigInt.from(boundary - cursor);
    final used = remaining < available ? remaining : available;
    values[local.hour] += used;
    remaining -= used;
    cursor += used.toInt();
    if (remaining > BigInt.zero) {
      offset = location.timeZone(cursor).offset.inMilliseconds;
    }
  }
}
