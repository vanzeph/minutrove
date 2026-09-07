import '../../data/sqlite_store.dart';
import '../../domain/domain.dart';

/// Session, appearance and earned amounts belong to the same committed read.
/// Rates remain frozen in the session snapshot; appearance follows current edits.
class SessionData {
  const SessionData({
    required this.session,
    required this.item,
    required this.earned,
    required this.remainders,
    this.award,
  });
  final Session session;
  final Item item;
  final CurrencyAmounts earned;
  final CurrencyAccrualRemainders remainders;
  final AwardBalance? award;

  CurrencyAmounts earningsAt(int remaining) {
    final configuration = session.itemSnapshot.configuration;
    if (configuration is! QuestConfiguration || !session.occupiesSlot) {
      return earned;
    }
    final unsettled =
        session.duration.value - remaining - session.settled.value;
    return earned +
        accrueCurrencies(
          ratesPerHour: configuration.ratesPerHour,
          active: Milliseconds(unsettled.clamp(0, session.duration.value)),
          remainders: remainders,
        ).amounts;
  }
}

Stream<SessionData?> watchSqliteSession(
  SqliteStore store,
  SessionId id,
) => store.watch((records) async {
  final session = await records.session(id);
  if (session == null) return null;
  var coins = 0;
  var gems = 0;
  for (final entry in await records.ledger(sessionId: id)) {
    switch (entry.dimension) {
      case VirtualCurrencyDimension(currency: VirtualCurrency.coins):
        coins = checkedInteger(BigInt.from(coins) + BigInt.from(entry.delta));
      case VirtualCurrencyDimension(currency: VirtualCurrency.gems):
        gems = checkedInteger(BigInt.from(gems) + BigInt.from(entry.delta));
      default:
        break;
    }
  }
  final itemId = session.itemSnapshot.id;
  return SessionData(
    session: session,
    item: await records.item(itemId) ?? session.itemSnapshot,
    earned: CurrencyAmounts(coins: MicroAmount(coins), gems: MicroAmount(gems)),
    remainders: (
      coins:
          (await records.remainder(itemId, VirtualCurrency.coins))?.remainder ??
          AccrualRemainder(0),
      gems:
          (await records.remainder(itemId, VirtualCurrency.gems))?.remainder ??
          AccrualRemainder(0),
    ),
    award: await records.award(itemId),
  );
});
