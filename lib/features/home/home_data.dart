import '../../data/sqlite_store.dart';
import '../../domain/domain.dart';

/// One committed read, so moving an item or consuming the last allowance cannot
/// expose a mixture of old groups, new definitions, and stale balances.
class HomeData {
  HomeData({
    required List<Item> items,
    required List<Group> groups,
    required List<AwardBalance> awards,
    required this.wallet,
    required this.activeSession,
  }) : items = List.unmodifiable(items),
       groups = List.unmodifiable(groups),
       awards = Map.unmodifiable({
         for (final award in awards) award.awardId: award,
       });

  final List<Item> items;
  final List<Group> groups;
  final Map<ItemId, AwardBalance> awards;
  final WalletProjection wallet;
  final Session? activeSession;

  Item? item(ItemId id) => items.where((item) => item.id == id).firstOrNull;

  bool visible(Item item) => switch (item.type) {
    ItemType.quest => !item.archived,
    // Purchased allowances remain usable even when future purchases are hidden.
    ItemType.award => awards[item.id]?.isExhausted == false,
  };

  List<Item> get launchers => items.where(visible).toList()
    ..sort((a, b) {
      final order = a.order.compareTo(b.order);
      return order == 0 ? a.id.value.compareTo(b.id.value) : order;
    });

  List<Group> get orderedGroups => List<Group>.of(groups)
    ..sort((a, b) {
      final order = a.order.compareTo(b.order);
      return order == 0 ? a.id.value.compareTo(b.id.value) : order;
    });
}

Stream<HomeData> watchSqliteHome(SqliteStore store) => store.watch(
  (records) async => HomeData(
    items: await records.items(),
    groups: await records.groups(),
    awards: await records.awards(),
    wallet: await records.wallet(),
    activeSession: await records.activeSession(),
  ),
);

String homeDuration(int milliseconds) {
  // Round only the display up to the next second, never a persisted balance.
  final seconds = milliseconds ~/ 1000 + (milliseconds % 1000 == 0 ? 0 : 1);
  final hours = seconds ~/ 3600;
  final minutes = seconds % 3600 ~/ 60;
  final remainder = seconds % 60;
  if (hours > 0) {
    return '${hours}h ${minutes}m${remainder > 0 ? ' ${remainder}s' : ''}';
  }
  if (minutes > 0) return '${minutes}m${remainder > 0 ? ' ${remainder}s' : ''}';
  return '${seconds}s';
}

String homeItemSummary(Item item, AwardBalance? award) =>
    switch (item.configuration) {
      QuestConfiguration(:final duration) => homeDuration(duration.value),
      AwardConfiguration() => [
        if (award?.time case final time?) homeDuration(time.value),
        if (award?.budget case final budget?) budget.toString(),
      ].join(' · '),
    };

/// Presentation only; the session/lifecycle adapter performs settlement.
int remainingSessionTime(Session session, ClockReading now) =>
    remainingSessionMilliseconds(session, now);
