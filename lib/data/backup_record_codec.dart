import '../domain/domain.dart';

/// Frozen v1 product-record allowlist. Deliberately separate from RecordCodec:
/// internal schema/result changes must not silently change a portable contract.
/// Device boot/monotonic anchors, deadlines and notification intents are omitted,
/// including those nested in historical operation results. Original operation
/// IDs, fingerprints, product results and wall-time history are preserved.
final class BackupRecordCodec {
  const BackupRecordCodec();

  Map<String, Object?> toJson(Object value) => _numbers(switch (value) {
    Operation<Object> v => {
      'type': 'operation',
      'id': v.id.value,
      'kind': v.kind.name,
      'fingerprint': v.requestFingerprint,
      'at': toJson(v.committedAt),
      'result': toJson(v.committedResult),
    },
    Item v => {
      'type': 'item',
      'id': v.id.value,
      'revision': v.revision.value,
      'name': v.name,
      'icon': v.iconKey,
      'color': v.colorArgb,
      'group': v.groupId?.value,
      'order': v.order,
      'archived': v.archived,
      'config': toJson(v.configuration),
    },
    QuestConfiguration v => {
      'type': 'quest',
      'duration': v.duration.value,
      'rates': toJson(v.ratesPerHour),
      'goal': v.dailyGoal == null ? null : toJson(v.dailyGoal!),
    },
    AwardConfiguration v => {
      'type': 'award',
      'pack': v.packName,
      'step': v.quantityStep,
      'price': toJson(v.price),
      'time': v.timeGrant?.value,
      'budget': v.budgetGrant == null ? null : toJson(v.budgetGrant!),
    },
    CurrencyAmounts v => {
      'type': 'amounts',
      'coins': v.coins.units,
      'gems': v.gems.units,
    },
    BudgetAmount v => {
      'type': 'budget',
      'currency': v.currency.code,
      'digits': v.currency.minorDigits,
      'minor': v.minorUnits,
    },
    DailyGoal v => {
      'type': 'goal',
      'target': v.target.value,
      'bonus': toJson(v.bonus),
    },
    Group v => {
      'type': 'group',
      'id': v.id.value,
      'revision': v.revision.value,
      'name': v.name,
      'order': v.order,
    },
    EventTime v => {
      'type': 'event',
      'utc': v.utc.millisecondsSinceEpoch,
      'day': day(v.day),
      'zone': v.zone.ianaName,
      'offset': v.offsetSeconds,
    },
    ClockReading v => {'type': 'instant', 'utc': v.utc.millisecondsSinceEpoch},
    ItemRevision v => {
      'type': 'itemRevision',
      'item': toJson(v.snapshot),
      'at': toJson(v.recordedAt),
    },
    ActiveInterval v => {
      'type': 'interval',
      'start': toJson(v.startedAt),
      'end': toJson(v.endedAt),
      'active': v.active.value,
      'at': toJson(v.assignment),
    },
    Session v => {
      'type': 'session',
      'id': v.id.value,
      'revision': v.revision.value,
      'item': toJson(v.itemSnapshot),
      'status': v.status.name,
      'zone': v.zone.ianaName,
      'start': toJson(v.startedAt),
      'checkpoint': toJson(v.checkpoint),
      'duration': v.duration.value,
      'settled': v.settled.value,
      'completion': v.completionId.value,
      'intervals': v.intervals.map(toJson).toList(),
    },
    LedgerEntry v => {
      'type': 'ledger',
      'id': v.id.value,
      'operation': v.operationId.value,
      'item': v.itemId.value,
      'revision': v.itemRevision.value,
      'session': v.sessionId?.value,
      'at': toJson(v.timestamp),
      'dimension': toJson(v.dimension),
      'delta': v.delta,
    },
    VirtualCurrencyDimension v => {
      'type': 'virtualDimension',
      'currency': v.currency.name,
    },
    TimeDimension _ => {'type': 'timeDimension'},
    BudgetDimension v => {
      'type': 'budgetDimension',
      'currency': v.currency.code,
      'digits': v.currency.minorDigits,
    },
    WalletProjection v => {
      'type': 'wallet',
      'revision': v.revision.value,
      'balances': toJson(v.balances),
    },
    AwardBalance v => {
      'type': 'balance',
      'id': v.awardId.value,
      'revision': v.revision.value,
      'time': v.time?.value,
      'budget': v.budget == null ? null : toJson(v.budget!),
    },
    QuestAccrualRemainder v => {
      'type': 'remainder',
      'id': v.questId.value,
      'currency': v.currency.name,
      'value': v.remainder.value,
    },
    DailyGoalRevision v => {
      'type': 'goalRevision',
      'id': v.questId.value,
      'revision': v.revision.value,
      'day': day(v.effectiveFrom),
      'zone': v.zone.ianaName,
      'goal': v.goal == null ? null : toJson(v.goal!),
    },
    DailyAchievement v => {
      'type': 'achievement',
      'id': v.questId.value,
      'day': day(v.day),
      'revision': v.goalRevision.value,
      'operation': v.operationId.value,
      'at': toJson(v.awardedAt),
      'bonus': toJson(v.bonus),
    },
    AppSettings v => {
      'type': 'settings',
      'revision': v.revision.value,
      'zone': v.reportingZone.ianaName,
    },
    SchemaVersion v => {'type': 'schema', 'value': v.value},
    EconomicState v => {
      'type': 'economy',
      'operation': v.operationId.value,
      'wallet': toJson(v.wallet),
      'awards': v.awards.map(toJson).toList(),
      'session': v.activeSession == null ? null : toJson(v.activeSession!),
      'entries': v.entries.map(toJson).toList(),
      'achievements': v.achievements.map(toJson).toList(),
    },
    SessionMutation v => {
      'type': 'sessionMutation',
      'session': toJson(v.session),
      'economy': toJson(v.economy),
    },
    RestoreReceipt v => {
      'type': 'restoreReceipt',
      'operation': v.operationId.value,
      'sha256': v.sourceSha256,
      'schema': toJson(v.schemaVersion),
      'settings': toJson(v.settings),
    },
    List<Item> v => {'type': 'items', 'items': v.map(toJson).toList()},
    bool v => {'type': 'bool', 'value': v},
    _ => throw const InvalidBackup('Unsupported portable record type'),
  });

  static String day(DayKey value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
}

Map<String, Object?> _numbers(Map<String, Object?> record) => {
  for (final entry in record.entries)
    entry.key: entry.value is int ? '${entry.value}' : entry.value,
};
