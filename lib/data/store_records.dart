import 'package:sqflite_common/sqlite_api.dart';

import '../domain/domain.dart';
import 'record_codec.dart';
import 'stats_reader.dart';

/// A transaction-scoped view. Do not retain it beyond its callback, nest store
/// transactions, or await user interaction while holding a transaction. A
/// bounded native clock sample is read by the coordinator before any mutation.
class StoreReader {
  StoreReader(this._db, this.codec);
  final DatabaseExecutor _db;
  final RecordCodec codec;

  /// Bounded, ledger-derived statistics inside this same read snapshot.
  Future<List<StatsBucket>> statistics(StatsQuery query) =>
      readStatistics(_db, query);

  Future<List<Map<String, Object?>>> _rows(
    String table, {
    String? where,
    List<Object?>? args,
    String? orderBy,
  }) => _db.query(table, where: where, whereArgs: args, orderBy: orderBy);

  Future<Item?> item(ItemId id) async {
    final rows = await _rows('items', where: 'id = ?', args: [id.value]);
    return rows.isEmpty ? null : _currentItem(rows.single);
  }

  Future<Item> _currentItem(Map<String, Object?> row) async {
    final revision = await itemRevision(
      ItemId(row['id'] as String),
      Revision(row['revision'] as int),
    );
    if (revision == null) {
      throw const FormatException('Missing current item revision');
    }
    final v = revision.snapshot;
    return Item(
      id: v.id,
      revision: v.revision,
      name: v.name,
      iconKey: v.iconKey,
      colorArgb: v.colorArgb,
      groupId: row['group_id'] == null
          ? null
          : GroupId(row['group_id'] as String),
      order: row['sort_order'] as int,
      archived: row['archived'] == 1,
      configuration: v.configuration,
    );
  }

  Future<List<Item>> items() async => Future.wait(
    (await _rows('items', orderBy: 'sort_order, id')).map(_currentItem),
  );
  Future<ItemRevision?> itemRevision(ItemId id, Revision revision) async {
    final rows = await _rows(
      'item_revisions',
      where: 'item_id = ? AND revision = ?',
      args: [id.value, revision.value],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final item = codec.decode<Item>(row['snapshot'] as String);
    if (item.id != id ||
        item.revision != revision ||
        item.type.name != row['type']) {
      throw const FormatException('Snapshot identity differs from row');
    }
    return ItemRevision(snapshot: item, recordedAt: _event(row, 'recorded'));
  }

  Future<Group?> group(GroupId id) async {
    final rows = await _rows('groups', where: 'id = ?', args: [id.value]);
    return rows.isEmpty ? null : _group(rows.single);
  }

  Future<List<Group>> groups() async =>
      (await _rows('groups', orderBy: 'sort_order, id')).map(_group).toList();
  Group _group(Map<String, Object?> r) => Group(
    id: GroupId(r['id'] as String),
    revision: Revision(r['revision'] as int),
    name: r['name'] as String,
    order: r['sort_order'] as int,
  );

  Future<Operation<T>?> operation<T extends Object>(OperationId id) async {
    final rows = await _rows('operations', where: 'id = ?', args: [id.value]);
    if (rows.isEmpty) return null;
    final r = rows.single;
    return Operation(
      id: id,
      kind: OperationKind.values.byName(r['kind'] as String),
      committedAt: _event(r, 'committed'),
      requestFingerprint: r['request_fingerprint'] as String,
      committedResult: codec.decode<T>(r['result'] as String),
    );
  }

  Future<Session?> session(SessionId id) async {
    final rows = await _rows('sessions', where: 'id = ?', args: [id.value]);
    return rows.isEmpty ? null : _session(rows.single);
  }

  Future<Session?> activeSession() async {
    final rows = await _rows(
      'sessions',
      where: "status IN ('running', 'paused')",
    );
    return rows.isEmpty ? null : _session(rows.single);
  }

  Future<Session> _session(Map<String, Object?> r) async {
    final snapshot = await itemRevision(
      ItemId(r['item_id'] as String),
      Revision(r['item_revision'] as int),
    );
    if (snapshot == null) {
      throw const FormatException('Missing session snapshot');
    }
    final intervals = await _rows(
      'active_intervals',
      where: 'session_id = ?',
      args: [r['id']],
      orderBy: 'ordinal',
    );
    return Session(
      id: SessionId(r['id'] as String),
      revision: Revision(r['revision'] as int),
      itemSnapshot: snapshot.snapshot,
      status: SessionStatus.values.byName(r['status'] as String),
      zone: ReportingZone(r['zone'] as String),
      startedAt: codec.decode(r['started_clock'] as String),
      checkpoint: codec.decode(r['checkpoint_clock'] as String),
      duration: Milliseconds(r['duration_ms'] as int),
      settled: Milliseconds(r['settled_ms'] as int),
      deadlineUtc: _nullableUtc(r['deadline_utc']),
      completionId: CompletionId(r['completion_id'] as String),
      intervals: intervals
          .map(
            (row) => ActiveInterval(
              startedAt: codec.decode(row['started_clock'] as String),
              endedAt: codec.decode(row['ended_clock'] as String),
              active: Milliseconds(row['active_ms'] as int),
              assignment: _event(row, 'assigned'),
            ),
          )
          .toList(),
    );
  }

  Future<List<LedgerEntry>> ledger({
    OperationId? operationId,
    ItemId? itemId,
    DayKey? from,
    DayKey? through,
  }) async {
    final clauses = <String>[];
    final args = <Object?>[];
    void filter(String clause, Object? value) {
      clauses.add(clause);
      args.add(value);
    }

    if (operationId != null) filter('operation_id = ?', operationId.value);
    if (itemId != null) filter('item_id = ?', itemId.value);
    if (from != null) filter('assigned_day >= ?', RecordCodec.day(from));
    if (through != null) filter('assigned_day <= ?', RecordCodec.day(through));
    return (await _rows(
      'ledger_entries',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      args: args,
      orderBy: 'assigned_utc, id',
    )).map(_ledger).toList();
  }

  LedgerEntry _ledger(Map<String, Object?> r) => LedgerEntry(
    id: LedgerId(r['id'] as String),
    operationId: OperationId(r['operation_id'] as String),
    itemId: ItemId(r['item_id'] as String),
    itemRevision: Revision(r['item_revision'] as int),
    sessionId: r['session_id'] == null
        ? null
        : SessionId(r['session_id'] as String),
    timestamp: _event(r, 'assigned'),
    dimension: switch (r['dimension']) {
      'coins' => const VirtualCurrencyDimension(VirtualCurrency.coins),
      'gems' => const VirtualCurrencyDimension(VirtualCurrency.gems),
      'time' => const TimeDimension(),
      'budget' => BudgetDimension(
        codec.currency(
          r['budget_currency'] as String,
          r['budget_digits'] as int,
        ),
      ),
      _ => throw const FormatException('Invalid ledger dimension'),
    },
    delta: r['delta'] as int,
  );

  Future<WalletProjection> wallet() async {
    final r = (await _rows('wallet_projection')).single;
    return WalletProjection(
      revision: Revision(r['revision'] as int),
      balances: CurrencyAmounts(
        coins: MicroAmount(r['coins'] as int),
        gems: MicroAmount(r['gems'] as int),
      ),
    );
  }

  Future<AwardBalance?> award(ItemId id) async {
    final rows = await _rows(
      'award_balances',
      where: 'award_id = ?',
      args: [id.value],
    );
    return rows.isEmpty ? null : _award(rows.single);
  }

  Future<List<AwardBalance>> awards() async =>
      (await _rows('award_balances', orderBy: 'award_id')).map(_award).toList();
  AwardBalance _award(Map<String, Object?> r) => AwardBalance(
    awardId: ItemId(r['award_id'] as String),
    revision: Revision(r['revision'] as int),
    time: r['time_ms'] == null ? null : Milliseconds(r['time_ms'] as int),
    budget: r['budget_minor'] == null
        ? null
        : BudgetAmount(
            codec.currency(
              r['budget_currency'] as String,
              r['budget_digits'] as int,
            ),
            r['budget_minor'] as int,
          ),
  );

  Future<QuestAccrualRemainder?> remainder(
    ItemId id,
    VirtualCurrency currency,
  ) async {
    final rows = await _rows(
      'quest_accrual_remainders',
      where: 'quest_id = ? AND currency = ?',
      args: [id.value, currency.name],
    );
    return rows.isEmpty
        ? null
        : QuestAccrualRemainder(
            questId: id,
            currency: currency,
            remainder: AccrualRemainder(rows.single['remainder'] as int),
          );
  }

  Future<List<DailyGoalRevision>> goals(ItemId id) async =>
      (await _rows(
            'daily_goal_revisions',
            where: 'quest_id = ?',
            args: [id.value],
            orderBy: 'effective_day, revision',
          ))
          .map(
            (r) => DailyGoalRevision(
              questId: id,
              revision: Revision(r['revision'] as int),
              effectiveFrom: RecordCodec.parseDay(r['effective_day'] as String),
              zone: ReportingZone(r['zone'] as String),
              goal: r['target_ms'] == null
                  ? null
                  : DailyGoal(
                      target: Milliseconds(r['target_ms'] as int),
                      bonus: CurrencyAmounts(
                        coins: MicroAmount(r['bonus_coins'] as int),
                        gems: MicroAmount(r['bonus_gems'] as int),
                      ),
                    ),
            ),
          )
          .toList();

  Future<List<DailyAchievement>> achievements({ItemId? questId}) async =>
      (await _rows(
            'daily_achievements',
            where: questId == null ? null : 'quest_id = ?',
            args: questId == null ? null : [questId.value],
            orderBy: 'day, quest_id',
          ))
          .map(
            (r) => DailyAchievement(
              questId: ItemId(r['quest_id'] as String),
              day: RecordCodec.parseDay(r['day'] as String),
              goalRevision: Revision(r['goal_revision'] as int),
              operationId: OperationId(r['operation_id'] as String),
              awardedAt: _event(r, 'awarded'),
              bonus: CurrencyAmounts(
                coins: MicroAmount(r['bonus_coins'] as int),
                gems: MicroAmount(r['bonus_gems'] as int),
              ),
            ),
          )
          .toList();

  Future<AppSettings> settings() async {
    final r = (await _rows('app_settings')).single;
    return AppSettings(
      revision: Revision(r['revision'] as int),
      reportingZone: ReportingZone(r['reporting_zone'] as String),
    );
  }

  /// Only committed Quest activity counts, with its original calendar key.
  /// Sum in Dart to avoid SQLite's signed integer SUM overflow.
  Future<BigInt> questActiveOn(ItemId id, DayKey day) async {
    final rows = await _db.rawQuery(
      '''SELECT delta FROM ledger_entries
      WHERE item_id = ? AND assigned_day = ? AND dimension = 'time'
        AND delta > 0 AND session_id IS NOT NULL''',
      [id.value, RecordCodec.day(day)],
    );
    return rows.fold<BigInt>(
      BigInt.zero,
      (total, row) => total + BigInt.from(row['delta'] as int),
    );
  }

  Future<List<NotificationIntent>> notificationIntents() async =>
      (await _rows('notification_intents', orderBy: 'session_id'))
          .map(
            (r) => NotificationIntent(
              sessionId: SessionId(r['session_id'] as String),
              sessionRevision: Revision(r['session_revision'] as int),
              completionId: CompletionId(r['completion_id'] as String),
              deadlineUtc: _nullableUtc(r['deadline_utc']),
              completionChimeHandled: r['chime_handled'] == 1,
            ),
          )
          .toList();

  Future<bool> hasHistory(ItemId id) async {
    final rows = await _db.rawQuery(
      '''SELECT EXISTS(SELECT 1 FROM sessions WHERE item_id = ?)
      OR EXISTS(SELECT 1 FROM ledger_entries WHERE item_id = ?)
      OR EXISTS(SELECT 1 FROM daily_achievements WHERE quest_id = ?) AS found''',
      [id.value, id.value, id.value],
    );
    return rows.single['found'] == 1;
  }

  /// Frozen day assignments include activity with no whole currency earned yet.
  Future<bool> hasActivityOn(ItemId id, DayKey day) async {
    final date = RecordCodec.day(day);
    final rows = await _db.rawQuery(
      '''SELECT EXISTS(SELECT 1 FROM active_intervals a
        JOIN sessions s ON s.id = a.session_id
        WHERE s.item_id = ? AND a.assigned_day = ? AND a.active_ms > 0)
      OR EXISTS(SELECT 1 FROM ledger_entries
        WHERE item_id = ? AND assigned_day = ? AND delta != 0)
      OR EXISTS(SELECT 1 FROM daily_achievements
        WHERE quest_id = ? AND day = ?) AS found''',
      [id.value, date, id.value, date, id.value, date],
    );
    return rows.single['found'] == 1;
  }

  /// BigInt aggregation avoids SQL SUM overflow even when the final total fits.
  /// Returns mismatch labels only; does not repair or rewrite history.
  Future<List<String>> projectionMismatches() async {
    final totals = <String, BigInt>{};
    for (final r in await _db.rawQuery(
      '''SELECT l.*, r.type AS item_type FROM ledger_entries l
      JOIN item_revisions r ON r.item_id = l.item_id AND r.revision = l.item_revision''',
    )) {
      final dimension = r['dimension'];
      if ((dimension == 'time' || dimension == 'budget') &&
          r['item_type'] != 'award') {
        continue;
      }
      final key = dimension == 'coins' || dimension == 'gems'
          ? '$dimension'
          : '${r['item_id']}:$dimension:${r['budget_currency'] ?? ''}:${r['budget_digits'] ?? ''}';
      totals.update(
        key,
        (value) => value + BigInt.from(r['delta'] as int),
        ifAbsent: () => BigInt.from(r['delta'] as int),
      );
    }
    final mismatches = <String>[];
    void check(String key, int amount) {
      if ((totals.remove(key) ?? BigInt.zero) != BigInt.from(amount)) {
        mismatches.add(key);
      }
    }

    final w = await wallet();
    check('coins', w.balances.coins.units);
    check('gems', w.balances.gems.units);
    for (final a in await awards()) {
      if (a.time != null) check('${a.awardId.value}:time::', a.time!.value);
      if (a.budget != null) {
        check(
          '${a.awardId.value}:budget:${a.budget!.currency.code}:${a.budget!.currency.minorDigits}',
          a.budget!.minorUnits,
        );
      }
    }
    mismatches.addAll(
      totals.entries.where((e) => e.value != BigInt.zero).map((e) => e.key),
    );
    return mismatches;
  }
}

final class StoreTransaction extends StoreReader {
  StoreTransaction(super.db, super.codec);

  // UPDATE then INSERT avoids INSERT OR REPLACE's implicit DELETE (and cascading
  // damage to history). SQLite's transaction owns visibility and uniqueness.
  Future<void> _put(
    String table,
    Map<String, Object?> values,
    String where,
    List<Object?> args,
  ) async {
    if (await _db.update(table, values, where: where, whereArgs: args) == 0) {
      await _db.insert(table, values);
    }
  }

  Future<void> putGroup(Group v) => _put(
    'groups',
    {
      'id': v.id.value,
      'revision': v.revision.value,
      'name': v.name,
      'sort_order': v.order,
    },
    'id = ?',
    [v.id.value],
  );
  Future<void> deleteGroup(GroupId id) async {
    await _db.delete('groups', where: 'id = ?', whereArgs: [id.value]);
  }

  /// Appends immutable history and points the current item at it, in one commit.
  /// The command layer owns expected-revision and history-safe edit validation.
  Future<void> putItem(ItemRevision v) async {
    final item = v.snapshot;
    await _db.insert('item_revisions', {
      'item_id': item.id.value,
      'revision': item.revision.value,
      'type': item.type.name,
      'snapshot': codec.encode(item),
      ..._eventRow(v.recordedAt, 'recorded'),
    });
    await _put(
      'items',
      {
        'id': item.id.value,
        'revision': item.revision.value,
        'group_id': item.groupId?.value,
        'sort_order': item.order,
        'archived': item.archived ? 1 : 0,
      },
      'id = ?',
      [item.id.value],
    );
  }

  Future<void> insertOperation<T extends Object>(Operation<T> v) async {
    await _db.insert('operations', {
      'id': v.id.value,
      'kind': v.kind.name,
      'request_fingerprint': v.requestFingerprint,
      'result': codec.encode(v.committedResult),
      ..._eventRow(v.committedAt, 'committed'),
    });
  }

  Future<void> putSession(Session v) async {
    final old = await session(v.id);
    if (old != null &&
        (old.itemSnapshot.id != v.itemSnapshot.id ||
            old.itemSnapshot.revision != v.itemSnapshot.revision ||
            old.completionId != v.completionId)) {
      throw const InvalidInput(
        'session',
        'Cannot change snapshot or completion identity',
      );
    }
    final saved = await itemRevision(
      v.itemSnapshot.id,
      v.itemSnapshot.revision,
    );
    if (saved == null ||
        codec.encode(saved.snapshot) != codec.encode(v.itemSnapshot)) {
      throw const InvalidInput(
        'session',
        'Snapshot must equal the stored revision',
      );
    }
    await _put(
      'sessions',
      {
        'id': v.id.value,
        'revision': v.revision.value,
        'item_id': v.itemSnapshot.id.value,
        'item_revision': v.itemSnapshot.revision.value,
        'status': v.status.name,
        'zone': v.zone.ianaName,
        'started_clock': codec.encode(v.startedAt),
        'checkpoint_clock': codec.encode(v.checkpoint),
        'duration_ms': v.duration.value,
        'settled_ms': v.settled.value,
        'deadline_utc': v.deadlineUtc?.millisecondsSinceEpoch,
        'completion_id': v.completionId.value,
      },
      'id = ?',
      [v.id.value],
    );
    await _db.delete(
      'active_intervals',
      where: 'session_id = ?',
      whereArgs: [v.id.value],
    );
    for (var i = 0; i < v.intervals.length; i++) {
      final interval = v.intervals[i];
      await _db.insert('active_intervals', {
        'session_id': v.id.value,
        'ordinal': i,
        'started_clock': codec.encode(interval.startedAt),
        'ended_clock': codec.encode(interval.endedAt),
        'active_ms': interval.active.value,
        ..._eventRow(interval.assignment, 'assigned'),
      });
    }
  }

  Future<void> insertLedger(LedgerEntry v) async {
    final dimension = v.dimension;
    await _db.insert('ledger_entries', {
      'id': v.id.value,
      'operation_id': v.operationId.value,
      'item_id': v.itemId.value,
      'item_revision': v.itemRevision.value,
      'session_id': v.sessionId?.value,
      'dimension': switch (dimension) {
        VirtualCurrencyDimension d => d.currency.name,
        TimeDimension _ => 'time',
        BudgetDimension _ => 'budget',
      },
      'budget_currency': dimension is BudgetDimension
          ? dimension.currency.code
          : null,
      'budget_digits': dimension is BudgetDimension
          ? dimension.currency.minorDigits
          : null,
      'delta': v.delta,
      ..._eventRow(v.timestamp, 'assigned'),
    });
  }

  Future<void> putWallet(WalletProjection v) => _put(
    'wallet_projection',
    {
      'singleton': 1,
      'revision': v.revision.value,
      'coins': v.balances.coins.units,
      'gems': v.balances.gems.units,
    },
    'singleton = 1',
    [],
  );
  Future<void> putAward(AwardBalance v) async {
    final definition = await item(v.awardId);
    final config = definition?.configuration;
    if (config is! AwardConfiguration ||
        (config.timeGrant == null) != (v.time == null) ||
        config.budgetGrant?.currency != v.budget?.currency) {
      throw const InvalidInput('allowance', 'Dimensions must match the Award');
    }
    await _put(
      'award_balances',
      {
        'award_id': v.awardId.value,
        'revision': v.revision.value,
        'time_ms': v.time?.value,
        'budget_minor': v.budget?.minorUnits,
        'budget_currency': v.budget?.currency.code,
        'budget_digits': v.budget?.currency.minorDigits,
      },
      'award_id = ?',
      [v.awardId.value],
    );
  }

  Future<void> putRemainder(QuestAccrualRemainder v) async {
    await _requireQuest(v.questId);
    await _put(
      'quest_accrual_remainders',
      {
        'quest_id': v.questId.value,
        'currency': v.currency.name,
        'remainder': v.remainder.value,
      },
      'quest_id = ? AND currency = ?',
      [v.questId.value, v.currency.name],
    );
  }

  Future<void> insertGoal(DailyGoalRevision v) async {
    await _requireQuest(v.questId);
    await _db.insert('daily_goal_revisions', {
      'quest_id': v.questId.value,
      'revision': v.revision.value,
      'effective_day': RecordCodec.day(v.effectiveFrom),
      'zone': v.zone.ianaName,
      'target_ms': v.goal?.target.value,
      'bonus_coins': v.goal?.bonus.coins.units ?? 0,
      'bonus_gems': v.goal?.bonus.gems.units ?? 0,
    });
  }

  Future<void> insertAchievement(DailyAchievement v) async {
    await _requireQuest(v.questId);
    await _db.insert('daily_achievements', {
      'quest_id': v.questId.value,
      'day': RecordCodec.day(v.day),
      'goal_revision': v.goalRevision.value,
      'operation_id': v.operationId.value,
      ..._eventRow(v.awardedAt, 'awarded'),
      'bonus_coins': v.bonus.coins.units,
      'bonus_gems': v.bonus.gems.units,
    });
  }

  Future<void> _requireQuest(ItemId id) async {
    if ((await item(id))?.type != ItemType.quest) {
      throw const InvalidInput('quest', 'Expected a Quest');
    }
  }

  Future<void> putSettings(AppSettings v) => _put(
    'app_settings',
    {
      'singleton': 1,
      'revision': v.revision.value,
      'reporting_zone': v.reportingZone.ianaName,
    },
    'singleton = 1',
    [],
  );
  Future<void> putNotificationIntent(NotificationIntent v) => _put(
    'notification_intents',
    {
      'session_id': v.sessionId.value,
      'session_revision': v.sessionRevision.value,
      'completion_id': v.completionId.value,
      'deadline_utc': v.deadlineUtc?.millisecondsSinceEpoch,
      'chime_handled': v.completionChimeHandled ? 1 : 0,
    },
    'session_id = ?',
    [v.sessionId.value],
  );
}

DateTime? _nullableUtc(Object? value) =>
    value == null ? null : RecordCodec.utc(value as int);
EventTime _event(Map<String, Object?> row, String prefix) => EventTime(
  utc: RecordCodec.utc(row['${prefix}_utc'] as int),
  day: RecordCodec.parseDay(row['${prefix}_day'] as String),
  zone: ReportingZone(row['${prefix}_zone'] as String),
  offsetSeconds: row['${prefix}_offset'] as int,
);
Map<String, Object?> _eventRow(EventTime value, String prefix) => {
  '${prefix}_utc': value.utc.millisecondsSinceEpoch,
  '${prefix}_day': RecordCodec.day(value.day),
  '${prefix}_zone': value.zone.ianaName,
  '${prefix}_offset': value.offsetSeconds,
};
