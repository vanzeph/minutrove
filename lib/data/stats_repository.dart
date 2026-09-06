import '../domain/domain.dart';
import 'sqlite_store.dart';

/// Queries committed history only; reading never checkpoints an active session.
final class SqliteStatsRepository implements StatsRepository {
  const SqliteStatsRepository({required this.store});
  final SqliteStore store;

  @override
  Future<Result<List<StatsBucket>>> query(StatsQuery query) async {
    final result = await store.read<Result<List<StatsBucket>>>((reader) async {
      // Return input/arithmetic failures as values: the store correctly treats
      // thrown decoding failures as unavailable storage.
      try {
        if (query.itemId case final id?) {
          final item = await reader.item(id);
          if (item == null) return const Failure(NotFound());
          final config = item.configuration;
          final compatible = switch (query.metric) {
            StatsMetric.questTime ||
            StatsMetric.dailyGoalCompletion ||
            StatsMetric.coinsEarned ||
            StatsMetric.gemsEarned => config is QuestConfiguration,
            StatsMetric.coinsSpent ||
            StatsMetric.gemsSpent => config is AwardConfiguration,
            StatsMetric.awardTime =>
              config is AwardConfiguration && config.timeGrant != null,
            StatsMetric.budgetSpent =>
              config is AwardConfiguration &&
                  config.budgetGrant?.currency == query.budgetCurrency,
          };
          if (!compatible) {
            return const Failure(InvalidInput('metric', 'Incompatible item'));
          }
        }
        return Success(await reader.statistics(query));
      } on NumericOverflow catch (error) {
        return Failure(error);
      }
    });
    return switch (result) {
      Success(:final value) => value,
      Failure(:final error) => Failure(error),
    };
  }
}
