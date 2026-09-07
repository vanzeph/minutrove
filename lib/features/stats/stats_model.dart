import '../../domain/domain.dart';

/// These dates are civil calendar labels, matching StatsRepository's buckets.
DateTime statsDate(DayKey day) => DateTime.utc(day.year, day.month, day.day);
DayKey statsDay(DateTime date) => DayKey(date.year, date.month, date.day);

DateTime periodStart(StatsPeriod period, DayKey anchor) {
  final date = statsDate(anchor);
  return switch (period) {
    StatsPeriod.daily => date,
    StatsPeriod.weekly => date.subtract(Duration(days: date.weekday - 1)),
    StatsPeriod.monthly => DateTime.utc(date.year, date.month),
    StatsPeriod.yearly => DateTime.utc(date.year),
  };
}

DayKey? shiftPeriod(StatsPeriod period, DayKey anchor, int delta) {
  final date = periodStart(period, anchor);
  final next = switch (period) {
    StatsPeriod.daily => date.add(Duration(days: delta)),
    StatsPeriod.weekly => date.add(Duration(days: delta * 7)),
    StatsPeriod.monthly => DateTime.utc(date.year, date.month + delta),
    StatsPeriod.yearly => DateTime.utc(date.year + delta),
  };
  return next.year < 1 || next.year > 9999 ? null : statsDay(next);
}

const statsMonths = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const statsWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
String statsDateLabel(DateTime date) =>
    '${date.day} ${statsMonths[date.month - 1]} ${date.year}';
String periodLabel(StatsPeriod period, DayKey anchor) {
  final date = periodStart(period, anchor);
  return switch (period) {
    StatsPeriod.daily => statsDateLabel(date),
    StatsPeriod.weekly => _weekLabel(date),
    StatsPeriod.monthly => '${statsMonths[date.month - 1]} ${date.year}',
    StatsPeriod.yearly => '${date.year}',
  };
}

String _weekLabel(DateTime start) {
  final end = start.add(const Duration(days: 6));
  return start.year == end.year
      ? '${start.day} ${statsMonths[start.month - 1]} – ${statsDateLabel(end)}'
      : '${statsDateLabel(start)} – ${statsDateLabel(end)}';
}

String periodName(StatsPeriod period) => switch (period) {
  StatsPeriod.daily => 'Daily',
  StatsPeriod.weekly => 'Weekly',
  StatsPeriod.monthly => 'Monthly',
  StatsPeriod.yearly => 'Yearly',
};
String metricName(StatsMetric metric) => switch (metric) {
  StatsMetric.questTime => 'Quest minutes',
  StatsMetric.awardTime => 'Award minutes used',
  StatsMetric.budgetSpent => 'Budget spent',
  StatsMetric.coinsEarned => 'Coins earned',
  StatsMetric.coinsSpent => 'Coins spent',
  StatsMetric.gemsEarned => 'Gems earned',
  StatsMetric.gemsSpent => 'Gems spent',
  StatsMetric.dailyGoalCompletion => 'Daily goals completed',
};
String categoryName(StatsCategory category) => switch (category) {
  StatsCategory.all => 'All',
  StatsCategory.quests => 'Quests',
  StatsCategory.awards => 'Awards',
  StatsCategory.currencies => 'Currencies',
  StatsCategory.item => 'Item',
};

enum StatsGraph { bars, lines }

class StatsContext {
  StatsContext({
    required List<Item> items,
    required this.today,
    required this.zone,
  }) : items = List.unmodifiable(items);
  final List<Item> items;
  final DayKey today;
  final ReportingZone zone;
  List<BudgetCurrency> get currencies {
    final result = <BudgetCurrency>{};
    for (final item in items) {
      if (item.configuration case AwardConfiguration(:final budgetGrant?)) {
        result.add(budgetGrant.currency);
      }
    }
    return result.toList()..sort((a, b) => a.code.compareTo(b.code));
  }
}

class StatsSelection {
  const StatsSelection({
    this.category = StatsCategory.all,
    this.itemId,
    this.metric = StatsMetric.questTime,
    this.currency,
    this.graph = StatsGraph.bars,
  });
  final StatsCategory category;
  final ItemId? itemId;
  final StatsMetric metric;
  final BudgetCurrency? currency;
  final StatsGraph graph;

  Item? item(StatsContext context) =>
      context.items.where((item) => item.id == itemId).firstOrNull;
  String label(StatsContext context) => category == StatsCategory.item
      ? item(context) == null
            ? 'Unavailable item'
            : itemLabel(item(context)!)
      : categoryName(category);

  String? unavailable(StatsMetric candidate, StatsContext context) {
    final selected = item(context);
    if (category == StatsCategory.item && selected == null) {
      return 'This item is unavailable. Choose another item.';
    }
    final effectiveCategory = category == StatsCategory.item
        ? selected!.type == ItemType.quest
              ? StatsCategory.quests
              : StatsCategory.awards
        : category;
    final quest =
        candidate == StatsMetric.questTime ||
        candidate == StatsMetric.dailyGoalCompletion ||
        candidate == StatsMetric.coinsEarned ||
        candidate == StatsMetric.gemsEarned;
    final money =
        candidate == StatsMetric.coinsEarned ||
        candidate == StatsMetric.coinsSpent ||
        candidate == StatsMetric.gemsEarned ||
        candidate == StatsMetric.gemsSpent;
    if (effectiveCategory == StatsCategory.quests && !quest) {
      return 'Choose Awards or All for this measure.';
    }
    if (effectiveCategory == StatsCategory.awards && quest) {
      return 'Choose Quests or All for this measure.';
    }
    if (effectiveCategory == StatsCategory.currencies && !money) {
      return 'Choose Quests, Awards or All for this measure.';
    }
    if (selected?.configuration case AwardConfiguration(
      :final timeGrant,
      :final budgetGrant,
    )) {
      if (candidate == StatsMetric.awardTime && timeGrant == null) {
        return 'This Award has no time allowance.';
      }
      if (candidate == StatsMetric.budgetSpent && budgetGrant == null) {
        return 'This Award has no budget allowance.';
      }
    }
    if (candidate == StatsMetric.budgetSpent && context.currencies.isEmpty) {
      return 'Create an Award with a budget to use this measure.';
    }
    return null;
  }

  List<BudgetCurrency> currencies(StatsContext context) {
    if (item(context)?.configuration case AwardConfiguration(
      :final budgetGrant?,
    )) {
      return [budgetGrant.currency];
    }
    return context.currencies;
  }

  StatsSelection normalized(StatsContext context) {
    final candidate = unavailable(metric, context) == null
        ? metric
        : StatsMetric.values.firstWhere(
            (m) => unavailable(m, context) == null,
            orElse: () => StatsMetric.questTime,
          );
    final options = currencies(context);
    return StatsSelection(
      category: category,
      itemId: itemId,
      metric: candidate,
      currency: candidate == StatsMetric.budgetSpent
          ? options.where((c) => c == currency).firstOrNull ??
                options.firstOrNull
          : null,
      graph: graph,
    );
  }

  StatsQuery query(StatsPeriod period, DayKey anchor) => StatsQuery(
    period: period,
    anchor: anchor,
    category: category,
    metric: metric,
    itemId: itemId,
    budgetCurrency: metric == StatsMetric.budgetSpent ? currency : null,
  );
}

String itemLabel(Item item) =>
    '${item.name}${item.archived ? ' (archived)' : ''}';

/// Exact integer formatting for currencies and counts, including int64 values.
/// Time is displayed to 0.001 minute; nonzero sub-resolution values stay visible.
String statsValue(BigInt raw, StatsMetric metric, BudgetCurrency? currency) {
  if (metric == StatsMetric.questTime || metric == StatsMetric.awardTime) {
    if (raw > BigInt.zero && raw < BigInt.from(60)) return '<0.001';
    return _decimal((raw + BigInt.from(30)) ~/ BigInt.from(60), 3);
  }
  return _decimal(raw, switch (metric) {
    StatsMetric.budgetSpent => currency!.minorDigits,
    StatsMetric.dailyGoalCompletion => 0,
    _ => 6,
  }, fixed: metric == StatsMetric.budgetSpent);
}

String _decimal(BigInt value, int digits, {bool fixed = false}) {
  final divisor = BigInt.from(10).pow(digits);
  final whole = (value ~/ divisor).toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+$)'),
    (match) => '${match[1]},',
  );
  if (digits == 0) return whole;
  var fraction = (value % divisor).toString().padLeft(digits, '0');
  if (!fixed) fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? whole : '$whole.$fraction';
}

String statsUnit(StatsMetric metric, BudgetCurrency? currency) =>
    switch (metric) {
      StatsMetric.questTime || StatsMetric.awardTime => 'min',
      StatsMetric.budgetSpent => currency!.code,
      StatsMetric.coinsEarned || StatsMetric.coinsSpent => 'Coins',
      StatsMetric.gemsEarned || StatsMetric.gemsSpent => 'Gems',
      StatsMetric.dailyGoalCompletion => 'goals',
    };
String bucketLabel(StatsPeriod period, StatsBucket bucket) => switch (period) {
  StatsPeriod.daily => '${bucket.start.hour.toString().padLeft(2, '0')}:00',
  StatsPeriod.weekly =>
    '${statsWeekdays[bucket.start.weekday - 1]} ${bucket.start.day}',
  StatsPeriod.monthly => '${bucket.start.day}',
  StatsPeriod.yearly => statsMonths[bucket.start.month - 1],
};
