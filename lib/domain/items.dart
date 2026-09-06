import 'result.dart';
import 'values.dart';

enum ItemType { quest, award }

sealed class ItemConfiguration {
  const ItemConfiguration();
  ItemType get type;
}

final class DailyGoal {
  DailyGoal({required this.target, required this.bonus}) {
    _positiveSeconds(target, 'dailyGoal');
  }
  final Milliseconds target;
  final CurrencyAmounts bonus;
}

void _positiveSeconds(Milliseconds value, String field) {
  if (value.value == 0 || value.value % 1000 != 0) {
    throw InvalidInput(field, 'Expected positive whole seconds');
  }
}

final class QuestConfiguration extends ItemConfiguration {
  QuestConfiguration({
    required this.duration,
    required this.ratesPerHour,
    this.dailyGoal,
  }) {
    _positiveSeconds(duration, 'duration');
    if (ratesPerHour.isZero) {
      throw const InvalidInput('rates', 'At least one rate must be positive');
    }
  }
  final Milliseconds duration;
  final CurrencyAmounts ratesPerHour;
  final DailyGoal? dailyGoal;
  @override
  ItemType get type => ItemType.quest;
}

final class AwardConfiguration extends ItemConfiguration {
  AwardConfiguration({
    required String packName,
    required this.price,
    this.timeGrant,
    this.budgetGrant,
    this.quantityStep = 1,
  }) : packName = nonEmpty(packName, 'packName') {
    if (quantityStep != 1) {
      throw const InvalidInput('quantityStep', 'v1 uses whole packs');
    }
    if (price.isZero) {
      throw const InvalidInput('price', 'At least one price must be positive');
    }
    if (timeGrant == null && budgetGrant == null) {
      throw const InvalidInput('grants', 'At least one grant required');
    }
    if (timeGrant != null) _positiveSeconds(timeGrant!, 'timeGrant');
    if (budgetGrant?.minorUnits == 0) {
      throw const InvalidInput('budgetGrant', 'Must be positive');
    }
  }
  final String packName;
  final int quantityStep;
  final CurrencyAmounts price;
  final Milliseconds? timeGrant;
  final BudgetAmount? budgetGrant;
  @override
  ItemType get type => ItemType.award;
}

final class Item {
  Item({
    required this.id,
    required this.revision,
    required String name,
    required String iconKey,
    required this.colorArgb,
    required this.groupId,
    required int order,
    required this.archived,
    required this.configuration,
  }) : name = nonEmpty(name, 'name'),
       iconKey = nonEmpty(iconKey, 'iconKey'),
       order = nonNegative(order, 'order') {
    if (colorArgb < 0 || colorArgb > 0xffffffff) {
      throw const InvalidInput('color', 'Expected ARGB32');
    }
  }
  final ItemId id;
  final Revision revision;
  final String name;
  final String iconKey;
  final int colorArgb;

  /// Null is Ungrouped, not a synthetic persisted group.
  final GroupId? groupId;
  final int order;
  final bool archived;
  final ItemConfiguration configuration;
  ItemType get type => configuration.type;
}

/// History facts must be read inside the saving transaction, not trusted from UI.
Result<Item> validateItemEdit({
  required Item previous,
  required Item proposed,
  required Revision expectedRevision,
  required bool hasHistory,
  required bool hasActiveSession,
}) {
  if (previous.id != proposed.id) {
    return const Failure(InvalidInput('id', 'Cannot replace identity'));
  }
  if (previous.revision != expectedRevision) {
    return const Failure(StaleRevision());
  }
  if (hasActiveSession && proposed.archived) {
    return const Failure(ActiveSessionConflict());
  }
  if (hasHistory) {
    if (previous.type != proposed.type) {
      return const Failure(UnsupportedDimensionalEdit());
    }
    final before = previous.configuration;
    final after = proposed.configuration;
    if (before is AwardConfiguration &&
        after is AwardConfiguration &&
        ((before.timeGrant == null) != (after.timeGrant == null) ||
            (before.budgetGrant == null) != (after.budgetGrant == null) ||
            before.budgetGrant?.currency != after.budgetGrant?.currency)) {
      return const Failure(UnsupportedDimensionalEdit());
    }
  }
  return Success(proposed);
}

final class ItemRevision {
  const ItemRevision({required this.snapshot, required this.recordedAt});
  final Item snapshot;
  final EventTime recordedAt;
}

final class Group {
  Group({
    required this.id,
    required this.revision,
    required String name,
    required int order,
  }) : name = nonEmpty(name, 'groupName'),
       order = nonNegative(order, 'order');
  final GroupId id;
  final Revision revision;
  final String name;
  final int order;
}

/// Disabling a goal is a revision too. Effective date is chosen transactionally.
final class DailyGoalRevision {
  const DailyGoalRevision({
    required this.questId,
    required this.revision,
    required this.effectiveFrom,
    required this.zone,
    required this.goal,
  });
  final ItemId questId;
  final Revision revision;
  final DayKey effectiveFrom;
  final ReportingZone zone;
  final DailyGoal? goal;
}
