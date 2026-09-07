import '../../data/data.dart';
import '../../domain/domain.dart';
import 'stats_model.dart';

/// Feature adapter: one context subscription and one frozen four-period read.
abstract interface class StatsSource {
  Stream<StatsContext> watchContext();
  Future<Result<StatsContext>> refreshContext();
  Future<Result<List<List<StatsBucket>>>> load(List<StatsQuery> queries);
}

class SqliteStatsSource implements StatsSource {
  SqliteStatsSource({
    required this.store,
    required this.calendar,
    DateTime Function()? utcNow,
  }) : utcNow = utcNow ?? (() => DateTime.now().toUtc());
  final SqliteStore store;
  final ReportingCalendar calendar;
  final DateTime Function() utcNow;

  Future<StatsContext> _context(StoreReader reader) async {
    final settings = await reader.settings();
    return StatsContext(
      items: await reader.items(),
      today: calendar.assign(utcNow(), settings.reportingZone).day,
      zone: settings.reportingZone,
    );
  }

  @override
  Stream<StatsContext> watchContext() => store.watch(_context);
  @override
  Future<Result<StatsContext>> refreshContext() => store.read(_context);

  @override
  Future<Result<List<List<StatsBucket>>>> load(List<StatsQuery> queries) async {
    final result = await store.read<Result<List<List<StatsBucket>>>>((
      reader,
    ) async {
      try {
        final context = await _context(reader);
        final charts = <List<StatsBucket>>[];
        for (final query in queries) {
          final selection = StatsSelection(
            category: query.category,
            itemId: query.itemId,
            metric: query.metric,
            currency: query.budgetCurrency,
          );
          if (selection.unavailable(query.metric, context) != null ||
              (query.metric == StatsMetric.budgetSpent &&
                  !selection
                      .currencies(context)
                      .contains(query.budgetCurrency))) {
            return const Failure(
              InvalidInput('metric', 'Incompatible selection'),
            );
          }
          charts.add(await reader.statistics(query));
        }
        return Success(List.unmodifiable(charts));
      } on DomainError catch (error) {
        return Failure(error);
      }
    });
    return switch (result) {
      Success(:final value) => value,
      Failure(:final error) => Failure(error),
    };
  }
}
