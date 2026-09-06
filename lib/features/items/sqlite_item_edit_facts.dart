import '../../data/data.dart';
import 'item_editing.dart';

/// Optional SQLite composition adapter. Read facts and the actual committed
/// goal effective date together; widgets never infer dates from the device zone.
ReadItemEditFacts sqliteItemEditFacts(SqliteStore store) =>
    (id) => store.read((reader) async {
      final goals = await reader.goals(id);
      goals.sort((a, b) => b.revision.value.compareTo(a.revision.value));
      return ItemEditFacts(
        hasHistory: await reader.hasHistory(id),
        active: (await reader.activeSession())?.itemSnapshot.id == id,
        latestGoal: goals.isEmpty ? null : goals.first,
      );
    });
