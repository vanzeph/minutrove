import 'dart:convert';

import '../domain/domain.dart';
import 'sqlite_store.dart';
import 'store_records.dart';

/// Durable item/group commands. All validation uses the same transaction as the
/// write. Compose with the same store used by session and economy adapters.
final class SqliteItemRepository implements ItemRepository {
  const SqliteItemRepository({
    required this.store,
    required this.clock,
    required this.calendar,
  });

  final SqliteStore store;
  final Clock clock;
  final ReportingCalendar calendar;

  @override
  Future<Result<Item?>> getItem(ItemId id) => store.read((r) => r.item(id));
  @override
  Stream<List<Item>> watchItems() => store.watch((r) => r.items());
  @override
  Stream<List<Group>> watchGroups() => store.watch((r) => r.groups());

  Future<Result<T>> _command<T extends Object>(
    OperationId id,
    OperationKind kind,
    Object Function(StoreTransaction) request,
    Future<T> Function(StoreTransaction, EventTime) apply,
  ) => store.write((tx) async {
    final fingerprint = jsonEncode([kind.name, request(tx)]);
    // Decode as Object first: reusing an ID from a different command must give
    // InvalidInput, even when its original result has a different Dart type.
    final previous = await tx.operation<Object>(id);
    if (previous != null) {
      if (previous.kind != kind || previous.requestFingerprint != fingerprint) {
        throw const InvalidInput(
          'operationId',
          'Already used for another request',
        );
      }
      return previous.committedResult as T;
    }
    final zone = (await tx.settings()).reportingZone;
    if (!calendar.supports(zone)) {
      throw const InvalidInput('reportingZone', 'Unsupported reporting zone');
    }
    final time = calendar.assign(clock.now().utc, zone);
    final result = await apply(tx, time);
    await tx.insertOperation(
      Operation(
        id: id,
        kind: kind,
        committedAt: time,
        requestFingerprint: fingerprint,
        committedResult: result,
      ),
    );
    return result;
  });

  @override
  Future<Result<Item>> saveItem({
    required OperationId operationId,
    required Item item,
    required Revision? expectedRevision,
  }) => _command(
    operationId,
    OperationKind.saveItem,
    (tx) => [tx.codec.toJson(item), expectedRevision?.value],
    (tx, time) => _save(tx, item, expectedRevision, time),
  );

  Future<Item> _save(
    StoreTransaction tx,
    Item proposed,
    Revision? expected,
    EventTime time,
  ) async {
    final previous = await tx.item(proposed.id);
    _checkRevision(previous?.revision, expected);
    if (proposed.groupId != null && await tx.group(proposed.groupId!) == null) {
      throw const NotFound();
    }
    if (previous != null) {
      final validation = validateItemEdit(
        previous: previous,
        proposed: proposed,
        expectedRevision: expected!,
        hasHistory: await tx.hasHistory(previous.id),
        hasActiveSession:
            (await tx.activeSession())?.itemSnapshot.id == previous.id,
      );
      if (validation is Failure<Item>) throw validation.error;
    }
    final saved = _copy(
      proposed,
      revision: previous?.revision.next() ?? Revision(1),
    );
    // Validate pinned currency metadata before persisting any snapshot.
    tx.codec.decode<Item>(tx.codec.encode(saved));
    await tx.putItem(ItemRevision(snapshot: saved, recordedAt: time));
    final before = previous?.configuration;
    final after = saved.configuration;
    final oldGoal = before is QuestConfiguration ? before.dailyGoal : null;
    final newGoal = after is QuestConfiguration ? after.dailyGoal : null;
    String? goalKey(DailyGoal? goal) =>
        goal == null ? null : tx.codec.encode(goal);
    if (after is QuestConfiguration &&
        (before is! QuestConfiguration ||
            goalKey(oldGoal) != goalKey(newGoal))) {
      final activity =
          await tx.hasActivityOn(saved.id, time.day) ||
          await _hasUnsettledActivity(tx, saved.id, time);
      final effective = activity
          ? calendar.assign(calendar.nextMidnight(time), time.zone).day
          : time.day;
      final goals = await tx.goals(saved.id);
      final revision = goals.isEmpty
          ? Revision(1)
          : Revision(
              goals
                  .map((g) => g.revision.value)
                  .reduce((a, b) => a > b ? a : b),
            ).next();
      await tx.insertGoal(
        DailyGoalRevision(
          questId: saved.id,
          revision: revision,
          effectiveFrom: effective,
          zone: time.zone,
          goal: newGoal,
        ),
      );
    }
    return saved;
  }

  Future<bool> _hasUnsettledActivity(
    StoreReader tx,
    ItemId id,
    EventTime time,
  ) async {
    final active = await tx.activeSession();
    if (active == null ||
        active.itemSnapshot.id != id ||
        active.status != SessionStatus.running) {
      return false;
    }
    final end = active.deadlineUtc!.isBefore(time.utc)
        ? active.deadlineUtc!
        : time.utc;
    if (!end.isAfter(active.checkpoint.utc)) return false;
    final first = calendar.assign(active.checkpoint.utc, active.zone).day;
    final last = calendar
        .assign(end.subtract(const Duration(milliseconds: 1)), active.zone)
        .day;
    int ordinal(DayKey day) => day.year * 10000 + day.month * 100 + day.day;
    return ordinal(first) <= ordinal(time.day) &&
        ordinal(last) >= ordinal(time.day);
  }

  @override
  Future<Result<Item>> archiveItem({
    required OperationId operationId,
    required ItemId itemId,
    required Revision expectedRevision,
  }) => _command(
    operationId,
    OperationKind.archiveItem,
    (_) => [itemId.value, expectedRevision.value],
    (tx, time) async {
      final item = await tx.item(itemId);
      if (item == null) throw const NotFound();
      return _save(tx, _copy(item, archived: true), expectedRevision, time);
    },
  );

  @override
  Future<Result<Group>> saveGroup({
    required OperationId operationId,
    required Group group,
    required Revision? expectedRevision,
  }) => _command(
    operationId,
    OperationKind.saveGroup,
    (tx) => [tx.codec.toJson(group), expectedRevision?.value],
    (tx, _) async {
      final previous = await tx.group(group.id);
      _checkRevision(previous?.revision, expectedRevision);
      final saved = Group(
        id: group.id,
        revision: previous?.revision.next() ?? Revision(1),
        name: group.name,
        order: group.order,
      );
      await tx.putGroup(saved);
      return saved;
    },
  );

  @override
  Future<Result<List<Item>>> removeGroup({
    required OperationId operationId,
    required GroupId groupId,
    required Revision expectedRevision,
  }) => _command(
    operationId,
    OperationKind.removeGroup,
    (_) => [groupId.value, expectedRevision.value],
    (tx, time) async {
      final group = await tx.group(groupId);
      _checkRevision(group?.revision, expectedRevision);
      final moved = <Item>[];
      for (final item in await tx.items()) {
        if (item.groupId != groupId) continue;
        final saved = _copy(
          item,
          revision: item.revision.next(),
          ungroup: true,
        );
        await tx.putItem(ItemRevision(snapshot: saved, recordedAt: time));
        moved.add(saved);
      }
      await tx.deleteGroup(groupId);
      return List<Item>.unmodifiable(moved);
    },
  );
}

void _checkRevision(Revision? current, Revision? expected) {
  if (current == null && expected != null) throw const NotFound();
  if (current != null && current != expected) throw const StaleRevision();
}

Item _copy(
  Item item, {
  Revision? revision,
  bool? archived,
  bool ungroup = false,
}) => Item(
  id: item.id,
  revision: revision ?? item.revision,
  name: item.name,
  iconKey: item.iconKey,
  colorArgb: item.colorArgb,
  groupId: ungroup ? null : item.groupId,
  order: item.order,
  archived: archived ?? item.archived,
  configuration: item.configuration,
);
