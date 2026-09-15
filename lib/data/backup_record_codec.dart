import '../domain/domain.dart';
import 'record_codec.dart';

/// Frozen v1 product-record allowlist. Deliberately separate from RecordCodec:
/// internal schema/result changes must not silently change a portable contract.
/// Device boot/monotonic anchors, deadlines and notification intents are omitted,
/// including those nested in historical operation results. Original operation
/// IDs, fingerprints, product results and wall-time history are preserved.
final class BackupRecordCodec {
  const BackupRecordCodec();

  /// Inverse of [toJson], used only by restore validation. Rebuilds typed
  /// product records from portable JSON; value constructors re-check every
  /// numeric range and identifier, surfacing violations as [InvalidBackup].
  /// Anchors export deliberately dropped are reconstructed inertly: clock
  /// endpoints gain a synthetic boot identity with zero monotonic time,
  /// running historical snapshots regain their checkpoint deadline, and
  /// session-mutation results regain a cancellation-only intent. Decoded
  /// historical results are replay data, never slot rows to schedule from.
  /// Pinned currency metadata must match the file exactly.
  Object fromJson(Object? input, CurrencyMetadata currencies) {
    try {
      return _PortableDecoder(RecordCodec(currencies)).decode(input);
    } on InvalidBackup {
      rethrow;
    } on DomainError {
      throw const InvalidBackup('Record validation failed');
    } on FormatException {
      throw const InvalidBackup('Record validation failed');
    }
  }

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

/// Synthetic boot identity shared by every reconstructed clock endpoint. The
/// portable format deliberately omits device anchors; zero monotonic time and
/// one shared identity keep intervals ordered without inventing device facts.
const restoredClockBootId = 'restored-backup';

/// Persisted commands paired with the portable result tag they must carry.
/// `exportBackup` is a read and never persists an operation row; adding a new
/// persisted kind requires extending this frozen contract and its fixtures.
const operationResultTypes = <OperationKind, String>{
  OperationKind.saveItem: 'item',
  OperationKind.archiveItem: 'item',
  OperationKind.saveGroup: 'group',
  OperationKind.removeGroup: 'items',
  OperationKind.startSession: 'sessionMutation',
  OperationKind.pauseSession: 'sessionMutation',
  OperationKind.resumeSession: 'sessionMutation',
  OperationKind.endSession: 'sessionMutation',
  OperationKind.reconcileSession: 'sessionMutation',
  OperationKind.redeemAward: 'economy',
  OperationKind.recordExpense: 'economy',
  OperationKind.saveSettings: 'settings',
  OperationKind.restoreBackup: 'restoreReceipt',
};

final class _PortableDecoder {
  _PortableDecoder(this.codec);
  final RecordCodec codec;

  Object decode(Object? input) {
    final m = _record(input);
    return switch (m['type']) {
      'item' => Item(
        id: ItemId(_text(m['id'])),
        revision: Revision(_integer(m['revision'])),
        name: _text(m['name']),
        iconKey: _text(m['icon']),
        colorArgb: _integer(m['color']),
        groupId: m['group'] == null ? null : GroupId(_text(m['group'])),
        order: _integer(m['order']),
        archived: _bool(m['archived']),
        configuration: _required<ItemConfiguration>(m, 'config'),
      ),
      'quest' => QuestConfiguration(
        duration: Milliseconds(_integer(m['duration'])),
        ratesPerHour: _required(m, 'rates'),
        dailyGoal: _optional(m, 'goal'),
      ),
      'award' => AwardConfiguration(
        packName: _text(m['pack']),
        quantityStep: _integer(m['step']),
        price: _required(m, 'price'),
        timeGrant: m['time'] == null ? null : Milliseconds(_integer(m['time'])),
        budgetGrant: _optional(m, 'budget'),
      ),
      'amounts' => CurrencyAmounts(
        coins: MicroAmount(_integer(m['coins'])),
        gems: MicroAmount(_integer(m['gems'])),
      ),
      'budget' => BudgetAmount(
        _currency(_text(m['currency']), _integer(m['digits'])),
        _integer(m['minor']),
      ),
      'goal' => DailyGoal(
        target: Milliseconds(_integer(m['target'])),
        bonus: _required(m, 'bonus'),
      ),
      'group' => Group(
        id: GroupId(_text(m['id'])),
        revision: Revision(_integer(m['revision'])),
        name: _text(m['name']),
        order: _integer(m['order']),
      ),
      'event' => EventTime(
        utc: RecordCodec.utc(_integer(m['utc'])),
        day: _day(_text(m['day'])),
        zone: ReportingZone(_text(m['zone'])),
        offsetSeconds: _integer(m['offset']),
      ),
      'instant' => ClockReading(
        utc: RecordCodec.utc(_integer(m['utc'])),
        bootId: restoredClockBootId,
        monotonic: Milliseconds(0),
      ),
      'itemRevision' => ItemRevision(
        snapshot: _required(m, 'item'),
        recordedAt: _required(m, 'at'),
      ),
      'interval' => ActiveInterval(
        startedAt: _required(m, 'start'),
        endedAt: _required(m, 'end'),
        active: Milliseconds(_integer(m['active'])),
        assignment: _required(m, 'at'),
      ),
      'session' => _session(m),
      'ledger' => LedgerEntry(
        id: LedgerId(_text(m['id'])),
        operationId: OperationId(_text(m['operation'])),
        itemId: ItemId(_text(m['item'])),
        itemRevision: Revision(_integer(m['revision'])),
        sessionId: m['session'] == null ? null : SessionId(_text(m['session'])),
        timestamp: _required(m, 'at'),
        dimension: _required(m, 'dimension'),
        delta: _integer(m['delta']),
      ),
      'virtualDimension' => VirtualCurrencyDimension(
        VirtualCurrency.values.asNameMap()[_text(m['currency'])] ??
            (throw _invalid()),
      ),
      'timeDimension' => const TimeDimension(),
      'budgetDimension' => BudgetDimension(
        _currency(_text(m['currency']), _integer(m['digits'])),
      ),
      'wallet' => WalletProjection(
        revision: Revision(_integer(m['revision'])),
        balances: _required(m, 'balances'),
      ),
      'balance' => AwardBalance(
        awardId: ItemId(_text(m['id'])),
        revision: Revision(_integer(m['revision'])),
        time: m['time'] == null ? null : Milliseconds(_integer(m['time'])),
        budget: _optional(m, 'budget'),
      ),
      'remainder' => QuestAccrualRemainder(
        questId: ItemId(_text(m['id'])),
        currency:
            VirtualCurrency.values.asNameMap()[_text(m['currency'])] ??
            (throw _invalid()),
        remainder: AccrualRemainder(_integer(m['value'])),
      ),
      'goalRevision' => DailyGoalRevision(
        questId: ItemId(_text(m['id'])),
        revision: Revision(_integer(m['revision'])),
        effectiveFrom: _day(_text(m['day'])),
        zone: ReportingZone(_text(m['zone'])),
        goal: _optional(m, 'goal'),
      ),
      'achievement' => DailyAchievement(
        questId: ItemId(_text(m['id'])),
        day: _day(_text(m['day'])),
        goalRevision: Revision(_integer(m['revision'])),
        operationId: OperationId(_text(m['operation'])),
        awardedAt: _required(m, 'at'),
        bonus: _required(m, 'bonus'),
      ),
      'settings' => AppSettings(
        revision: Revision(_integer(m['revision'])),
        reportingZone: ReportingZone(_text(m['zone'])),
      ),
      'schema' => SchemaVersion(_integer(m['value'])),
      'economy' => EconomicState(
        operationId: OperationId(_text(m['operation'])),
        wallet: _required(m, 'wallet'),
        awards: _list(m, 'awards'),
        activeSession: _optional(m, 'session'),
        entries: _list(m, 'entries'),
        achievements: _list(m, 'achievements'),
      ),
      'sessionMutation' => () {
        final session = _required<Session>(m, 'session');
        return SessionMutation(
          session: session,
          economy: _required(m, 'economy'),
          // Cancellation-only reconstruction; export omits the live intent.
          notificationIntent: NotificationIntent(
            sessionId: session.id,
            sessionRevision: session.revision,
            completionId: session.completionId,
            deadlineUtc: session.deadlineUtc,
            completionChimeHandled: false,
          ),
        );
      }(),
      'restoreReceipt' => RestoreReceipt(
        operationId: OperationId(_text(m['operation'])),
        sourceSha256: _text(m['sha256']),
        schemaVersion: _required(m, 'schema'),
        settings: _required(m, 'settings'),
      ),
      'items' => List<Item>.unmodifiable(_list(m, 'items')),
      'bool' => _bool(m['value']),
      'operation' => _operation(m),
      _ => throw _invalid(),
    };
  }

  Session _session(Map<String, Object?> m) {
    final status =
        SessionStatus.values.asNameMap()[_text(m['status'])] ??
        (throw _invalid());
    final duration = Milliseconds(_integer(m['duration']));
    final settled = Milliseconds(_integer(m['settled']));
    final checkpoint = _required<ClockReading>(m, 'checkpoint');
    // A running historical snapshot regains the deadline implied by its own
    // checkpoint and remaining time; terminal snapshots never carry one.
    return Session(
      id: SessionId(_text(m['id'])),
      revision: Revision(_integer(m['revision'])),
      itemSnapshot: _required(m, 'item'),
      status: status,
      zone: ReportingZone(_text(m['zone'])),
      startedAt: _required(m, 'start'),
      checkpoint: checkpoint,
      duration: duration,
      settled: settled,
      deadlineUtc: status == SessionStatus.running
          ? sessionDeadline(checkpoint.utc, duration - settled)
          : null,
      completionId: CompletionId(_text(m['completion'])),
      intervals: _list(m, 'intervals'),
    );
  }

  Operation<Object> _operation(Map<String, Object?> m) {
    final kind = OperationKind.values.asNameMap()[_text(m['kind'])];
    final expected = kind == null ? null : operationResultTypes[kind];
    if (expected == null) throw _invalid();
    final result = _record(m['result']);
    if (result['type'] != expected) throw _invalid();
    final fingerprint = _text(m['fingerprint']);
    if (fingerprint.isEmpty) throw _invalid();
    return Operation<Object>(
      id: OperationId(_text(m['id'])),
      kind: kind!,
      committedAt: _required(m, 'at'),
      requestFingerprint: fingerprint,
      committedResult: decode(result),
    );
  }

  BudgetCurrency _currency(String code, int digits) {
    try {
      return codec.currency(code, digits);
    } on FormatException {
      throw _invalid();
    }
  }

  Never _invalid() => throw const InvalidBackup('Unsupported portable record');

  String _text(Object? value) {
    if (value is! String) throw _invalid();
    return value;
  }

  bool _bool(Object? value) {
    if (value is! bool) throw _invalid();
    return value;
  }

  int _integer(Object? value) {
    if (value is! String) throw _invalid();
    return int.tryParse(value) ?? (throw _invalid());
  }

  Map<String, Object?> _record(Object? value) {
    if (value is! Map) throw _invalid();
    return Map<String, Object?>.from(value);
  }

  DayKey _day(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) throw _invalid();
    return RecordCodec.parseDay(value);
  }

  T _required<T extends Object>(Map<String, Object?> m, String key) =>
      decode(m[key]) as T;

  T? _optional<T extends Object>(Map<String, Object?> m, String key) =>
      m[key] == null ? null : decode(m[key]) as T;

  List<T> _list<T extends Object>(Map<String, Object?> m, String key) =>
      (m[key] as List? ?? (throw _invalid()))
          .map((value) => decode(value) as T)
          .toList();
}
