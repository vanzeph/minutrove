import '../../domain/domain.dart';

/// Mutable strings belong to a dialog, never to a persisted Item. Hidden type
/// sections retain their values when the user switches type or allowance kind.
class ItemDraft {
  ItemDraft({required this.id, Item? item})
    : original = item,
      type = item?.type ?? ItemType.quest,
      name = item?.name ?? '',
      iconKey = item?.iconKey ?? 'puzzle',
      colorArgb = item?.colorArgb ?? 0xff23755a,
      groupId = item?.groupId,
      order = item?.order ?? 0 {
    final config = item?.configuration;
    if (config is QuestConfiguration) {
      final durationValue = durationText(config.duration);
      duration = durationValue.$1;
      durationUnit = durationValue.$2;
      // Hours preserve every possible persisted millionth without division.
      rateUnit = TimeUnit.hours;
      coins = config.ratesPerHour.coins.toString();
      gems = config.ratesPerHour.gems.toString();
      final goal = config.dailyGoal;
      goalEnabled = goal != null;
      if (goal != null) {
        final goalValue = durationText(goal.target);
        goalDuration = goalValue.$1;
        goalUnit = goalValue.$2;
        bonusCoins = goal.bonus.coins.toString();
        bonusGems = goal.bonus.gems.toString();
      }
    } else if (config is AwardConfiguration) {
      packName = config.packName;
      priceCoins = config.price.coins.toString();
      priceGems = config.price.gems.toString();
      timeEnabled = config.timeGrant != null;
      budgetEnabled = config.budgetGrant != null;
      if (config.timeGrant != null) {
        final timeValue = durationText(config.timeGrant!);
        timeGrant = timeValue.$1;
        timeUnit = timeValue.$2;
      }
      final budget = config.budgetGrant;
      if (budget != null) {
        currencyCode = budget.currency.code;
        budgetGrant = budget.toString().split(' ').last;
      }
    }
  }

  final ItemId id;
  final Item? original;
  ItemType type;
  String name, iconKey;
  int colorArgb, order;
  GroupId? groupId;
  String duration = '', coins = '0', gems = '0';
  TimeUnit durationUnit = TimeUnit.minutes, rateUnit = TimeUnit.minutes;
  bool goalEnabled = false;
  String goalDuration = '', bonusCoins = '0', bonusGems = '0';
  TimeUnit goalUnit = TimeUnit.minutes;
  String packName = '', priceCoins = '0', priceGems = '0';
  bool timeEnabled = true, budgetEnabled = false;
  String timeGrant = '', budgetGrant = '', currencyCode = '';
  TimeUnit timeUnit = TimeUnit.minutes;

  static (String, TimeUnit) durationText(Milliseconds value) {
    for (final unit in [TimeUnit.hours, TimeUnit.minutes, TimeUnit.seconds]) {
      if (value.value % unit.milliseconds == 0) {
        return ('${value.value ~/ unit.milliseconds}', unit);
      }
    }
    throw const InvalidInput('duration', 'Expected whole seconds');
  }

  Item build(CurrencyMetadata currencies, {bool? archived}) {
    final ItemConfiguration configuration;
    if (type == ItemType.quest) {
      configuration = QuestConfiguration(
        duration: Milliseconds.parseConfiguration(
          duration.trim(),
          unit: durationUnit,
        ),
        ratesPerHour: CurrencyAmounts(
          coins: normalizeRatePerHour(coins.trim(), per: rateUnit),
          gems: normalizeRatePerHour(gems.trim(), per: rateUnit),
        ),
        dailyGoal: goalEnabled
            ? DailyGoal(
                target: Milliseconds.parseConfiguration(
                  goalDuration.trim(),
                  unit: goalUnit,
                ),
                bonus: CurrencyAmounts(
                  coins: MicroAmount.parse(bonusCoins.trim()),
                  gems: MicroAmount.parse(bonusGems.trim()),
                ),
              )
            : null,
      );
    } else {
      configuration = AwardConfiguration(
        packName: packName.trim(),
        price: CurrencyAmounts(
          coins: MicroAmount.parse(priceCoins.trim()),
          gems: MicroAmount.parse(priceGems.trim()),
        ),
        timeGrant: timeEnabled
            ? Milliseconds.parseConfiguration(timeGrant.trim(), unit: timeUnit)
            : null,
        budgetGrant: budgetEnabled
            ? BudgetAmount.parse(
                BudgetCurrency.fromMetadata(
                  currencyCode.trim().toUpperCase(),
                  currencies,
                ),
                budgetGrant.trim(),
              )
            : null,
      );
    }
    return Item(
      id: id,
      revision: original?.revision ?? Revision(1),
      name: name.trim(),
      iconKey: iconKey,
      colorArgb: colorArgb,
      groupId: groupId,
      order: order,
      archived: archived ?? original?.archived ?? false,
      configuration: configuration,
    );
  }
}
