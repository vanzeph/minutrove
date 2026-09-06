import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/items/items.dart';

import '../data/support.dart' as f;

void main() {
  test(
    'all Award dimensions and exact prices remain independent of appearance',
    () {
      for (final dimensions in [(true, false), (false, true), (true, true)]) {
        final draft = ItemDraft(id: ItemId(f.uuid(1)))
          ..type = ItemType.award
          ..name = 'A'
          ..iconKey = 'gamepad'
          ..colorArgb = 0xff7654a5
          ..packName = 'Pack'
          ..priceCoins = '0.000001'
          ..priceGems = '2'
          ..timeEnabled = dimensions.$1
          ..budgetEnabled = dimensions.$2
          ..timeGrant = '1.5'
          ..timeUnit = TimeUnit.minutes
          ..budgetGrant = '12.50'
          ..currencyCode = 'usd';
        final item = draft.build(f.metadata);
        final config = item.configuration as AwardConfiguration;
        expect(config.timeGrant?.value, dimensions.$1 ? 90000 : null);
        expect(config.budgetGrant?.minorUnits, dimensions.$2 ? 1250 : null);
        expect(config.price.coins.units, 1);
        expect(config.price.gems.units, 2000000);
        expect(item.iconKey, 'gamepad');
        expect(item.colorArgb, 0xff7654a5);
      }
    },
  );
  test(
    'persisted rates and whole seconds round trip without display rounding',
    () {
      final original = f.quest();
      final item = Item(
        id: original.id,
        revision: original.revision,
        name: original.name,
        iconKey: original.iconKey,
        colorArgb: original.colorArgb,
        groupId: null,
        order: 7,
        archived: false,
        configuration: QuestConfiguration(
          duration: Milliseconds.seconds(61),
          ratesPerHour: f.amounts(1, 7),
          dailyGoal: DailyGoal(
            target: Milliseconds.seconds(3599),
            bonus: f.amounts(0),
          ),
        ),
      );
      final draft = ItemDraft(id: item.id, item: item)..name = 'Renamed';
      final result =
          draft.build(f.metadata).configuration as QuestConfiguration;
      expect(result.ratesPerHour.coins.units, 1);
      expect(result.ratesPerHour.gems.units, 7);
      expect(result.duration.value, 61000);
      expect(result.dailyGoal!.target.value, 3599000);
    },
  );
  test('invalid numeric drafts cannot construct items', () {
    for (final invalid in [
      'NaN',
      'Infinity',
      '-1',
      '1e4',
      '0.0000001',
      '999999999999999999999',
    ]) {
      final draft = ItemDraft(id: ItemId(f.uuid(1)))
        ..name = 'Q'
        ..duration = '1'
        ..coins = invalid;
      expect(() => draft.build(f.metadata), throwsA(isA<DomainError>()));
    }
    final draft = ItemDraft(id: ItemId(f.uuid(1)))
      ..name = 'A'
      ..type = ItemType.award
      ..packName = 'P'
      ..priceCoins = '1'
      ..timeEnabled = false
      ..budgetEnabled = true
      ..currencyCode = 'JPY'
      ..budgetGrant = '1.50';
    expect(() => draft.build(f.metadata), throwsA(isA<InvalidInput>()));
  });
}
