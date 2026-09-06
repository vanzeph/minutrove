import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/domain/domain.dart';

import 'values_test.dart' show TestCurrencies;

CurrencyAmounts money(int coins, [int gems = 0]) =>
    CurrencyAmounts(coins: MicroAmount(coins), gems: MicroAmount(gems));
Item item(
  ItemConfiguration configuration, {
  bool archived = false,
  int revision = 1,
  String name = 'Synthetic item',
  int color = 0xff112233,
}) => Item(
  id: ItemId('00000000-0000-0000-0000-000000000001'),
  revision: Revision(revision),
  name: name,
  iconKey: 'gamepad',
  colorArgb: color,
  groupId: null,
  order: 0,
  archived: archived,
  configuration: configuration,
);
QuestConfiguration quest() => QuestConfiguration(
  duration: Milliseconds.seconds(60),
  ratesPerHour: money(100),
);
AwardConfiguration award({bool time = true, String? currency, int cost = 1}) =>
    AwardConfiguration(
      packName: 'pack',
      price: money(cost),
      timeGrant: time ? Milliseconds.seconds(60) : null,
      budgetGrant: currency == null
          ? null
          : BudgetAmount(
              BudgetCurrency.fromMetadata(currency, TestCurrencies()),
              100,
            ),
    );

void main() {
  test('configuration rejects zero rates, price, duration, and grants', () {
    expect(
      () => QuestConfiguration(
        duration: Milliseconds.seconds(1),
        ratesPerHour: money(0),
      ),
      throwsA(isA<InvalidInput>()),
    );
    expect(
      () =>
          QuestConfiguration(duration: Milliseconds(1), ratesPerHour: money(1)),
      throwsA(isA<InvalidInput>()),
    );
    expect(
      () =>
          QuestConfiguration(duration: Milliseconds(0), ratesPerHour: money(1)),
      throwsA(isA<InvalidInput>()),
    );
    expect(() => award(cost: 0), throwsA(isA<InvalidInput>()));
    expect(() => award(time: false), throwsA(isA<InvalidInput>()));
    expect(
      () => AwardConfiguration(
        packName: 'x',
        price: money(1),
        timeGrant: Milliseconds.seconds(1),
        quantityStep: 2,
      ),
      throwsA(isA<InvalidInput>()),
    );
    expect(
      DailyGoal(target: Milliseconds.seconds(60), bonus: money(0)).bonus.isZero,
      isTrue,
    );
  });

  test('shared icon and color do not define type or rates', () {
    expect(item(quest()).iconKey, item(award()).iconKey);
    expect(item(quest()).colorArgb, item(award()).colorArgb);
    expect(item(quest()).type, ItemType.quest);
    expect(item(award()).type, ItemType.award);
  });

  test('history locks type, grant dimensions, and budget currency', () {
    final before = item(award(currency: 'USD'));
    for (final config in [
      quest(),
      award(),
      award(time: false, currency: 'USD'),
      award(currency: 'JPY'),
    ]) {
      final result = validateItemEdit(
        previous: before,
        proposed: item(config),
        expectedRevision: Revision(1),
        hasHistory: true,
        hasActiveSession: false,
      );
      expect(
        (result as Failure<Item>).error,
        isA<UnsupportedDimensionalEdit>(),
      );
    }
    expect(
      validateItemEdit(
        previous: item(quest()),
        proposed: item(award()),
        expectedRevision: Revision(1),
        hasHistory: false,
        hasActiveSession: false,
      ),
      isA<Success<Item>>(),
    );
  });

  test(
    'cosmetic and future price edits are allowed; revisions and slot checked',
    () {
      final before = item(award(currency: 'USD'));
      final changed = item(
        award(currency: 'USD', cost: 2),
        name: 'New name',
        color: 0xff334455,
      );
      expect(
        validateItemEdit(
          previous: before,
          proposed: changed,
          expectedRevision: Revision(1),
          hasHistory: true,
          hasActiveSession: false,
        ),
        isA<Success<Item>>(),
      );
      expect(
        (validateItemEdit(
          previous: before,
          proposed: changed,
          expectedRevision: Revision(2),
          hasHistory: true,
          hasActiveSession: false,
        ) as Failure<Item>).error,
        isA<StaleRevision>(),
      );
      expect(
        (validateItemEdit(
          previous: before,
          proposed: item(award(currency: 'USD'), archived: true),
          expectedRevision: Revision(1),
          hasHistory: true,
          hasActiveSession: true,
        ) as Failure<Item>).error,
        isA<ActiveSessionConflict>(),
      );
    },
  );

  test('combined allowance persists until both dimensions are exhausted', () {
    final usd = BudgetCurrency.fromMetadata('USD', TestCurrencies());
    final balance = AwardBalance(
      awardId: item(award()).id,
      revision: Revision(1),
      time: Milliseconds(0),
      budget: BudgetAmount(usd, 1),
    );
    expect(balance.isExhausted, isFalse);
    expect(
      AwardBalance(
        awardId: balance.awardId,
        revision: balance.revision,
        time: Milliseconds(0),
        budget: BudgetAmount(usd, 0),
      ).isExhausted,
      isTrue,
    );
  });

  test('preview checks both prices, grants, affordability, and overflow', () {
    final definition = item(
      AwardConfiguration(
        packName: 'both',
        price: money(2, 3),
        timeGrant: Milliseconds.seconds(60),
      ),
    );
    final result = previewRedemption(
      award: definition,
      quantity: PurchaseQuantity(3),
      wallet: money(10, 10),
    ) as Success<RedemptionPreview>;
    expect(result.value.maximumAffordableQuantity, 3);
    expect(result.value.walletAfter.coins.units, 4);
    expect(result.value.walletAfter.gems.units, 1);
    expect(result.value.timeGrant!.value, 180000);
    final short = previewRedemption(
      award: definition,
      quantity: PurchaseQuantity(4),
      wallet: money(10, 10),
    ) as Failure<RedemptionPreview>;
    expect((short.error as InsufficientFunds).gems, isTrue);
    expect(
      previewRedemption(
        award: item(award()),
        quantity: PurchaseQuantity(1),
        wallet: money(1, 0),
      ),
      isA<Success<RedemptionPreview>>(),
    );
    expect(
      (previewRedemption(
        award: item(award(cost: maxStoredInteger)),
        quantity: PurchaseQuantity(2),
        wallet: money(maxStoredInteger),
      ) as Failure<RedemptionPreview>).error,
      isA<NumericOverflow>(),
    );
    expect(() => PurchaseQuantity(0), throwsA(isA<InvalidInput>()));
  });
}
