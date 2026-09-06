import 'dart:convert';

import '../domain/domain.dart';

/// Version-one internal record encoding, including immutable operation results.
/// This is not the portable backup format. Currency metadata must be pinned by
/// the caller; persisted precision is checked rather than silently reinterpreted.
final class RecordCodec {
  const RecordCodec(this.currencies);
  final CurrencyMetadata currencies;

  String encode(Object value) => jsonEncode(toJson(value));
  T decode<T extends Object>(String value) => fromJson(jsonDecode(value)) as T;

  Map<String, Object?> toJson(Object value) => switch (value) {
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
    ClockReading v => {
      'type': 'clock',
      'utc': v.utc.millisecondsSinceEpoch,
      'boot': v.bootId,
      'monotonic': v.monotonic.value,
    },
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
      'deadline': v.deadlineUtc?.millisecondsSinceEpoch,
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
    NotificationIntent v => {
      'type': 'notification',
      'id': v.sessionId.value,
      'revision': v.sessionRevision.value,
      'completion': v.completionId.value,
      'deadline': v.deadlineUtc?.millisecondsSinceEpoch,
      'handled': v.completionChimeHandled,
    },
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
      'intent': toJson(v.notificationIntent),
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
    _ => throw const InvalidInput('record', 'Unsupported durable result type'),
  };

  Object fromJson(Object? input) {
    final m = Map<String, Object?>.from(input as Map);
    T child<T extends Object>(String key) => fromJson(m[key]) as T;
    T? optional<T extends Object>(String key) =>
        m[key] == null ? null : child<T>(key);
    List<T> list<T extends Object>(String key) =>
        (m[key] as List).map((v) => fromJson(v) as T).toList();
    int number(String key) => m[key] as int;
    String text(String key) => m[key] as String;
    Revision revision() => Revision(number('revision'));
    Milliseconds? time(String key) =>
        m[key] == null ? null : Milliseconds(number(key));
    DateTime? deadline() =>
        m['deadline'] == null ? null : utc(number('deadline'));
    return switch (m['type']) {
      'item' => Item(
        id: ItemId(text('id')),
        revision: revision(),
        name: text('name'),
        iconKey: text('icon'),
        colorArgb: number('color'),
        groupId: m['group'] == null ? null : GroupId(text('group')),
        order: number('order'),
        archived: m['archived'] as bool,
        configuration: child('config'),
      ),
      'quest' => QuestConfiguration(
        duration: Milliseconds(number('duration')),
        ratesPerHour: child('rates'),
        dailyGoal: optional('goal'),
      ),
      'award' => AwardConfiguration(
        packName: text('pack'),
        quantityStep: number('step'),
        price: child('price'),
        timeGrant: time('time'),
        budgetGrant: optional('budget'),
      ),
      'amounts' => CurrencyAmounts(
        coins: MicroAmount(number('coins')),
        gems: MicroAmount(number('gems')),
      ),
      'budget' => BudgetAmount(
        currency(text('currency'), number('digits')),
        number('minor'),
      ),
      'goal' => DailyGoal(
        target: Milliseconds(number('target')),
        bonus: child('bonus'),
      ),
      'group' => Group(
        id: GroupId(text('id')),
        revision: revision(),
        name: text('name'),
        order: number('order'),
      ),
      'event' => EventTime(
        utc: utc(number('utc')),
        day: parseDay(text('day')),
        zone: ReportingZone(text('zone')),
        offsetSeconds: number('offset'),
      ),
      'clock' => ClockReading(
        utc: utc(number('utc')),
        bootId: text('boot'),
        monotonic: Milliseconds(number('monotonic')),
      ),
      'itemRevision' => ItemRevision(
        snapshot: child('item'),
        recordedAt: child('at'),
      ),
      'interval' => ActiveInterval(
        startedAt: child('start'),
        endedAt: child('end'),
        active: Milliseconds(number('active')),
        assignment: child('at'),
      ),
      'session' => Session(
        id: SessionId(text('id')),
        revision: revision(),
        itemSnapshot: child('item'),
        status: SessionStatus.values.byName(text('status')),
        zone: ReportingZone(text('zone')),
        startedAt: child('start'),
        checkpoint: child('checkpoint'),
        duration: Milliseconds(number('duration')),
        settled: Milliseconds(number('settled')),
        deadlineUtc: deadline(),
        completionId: CompletionId(text('completion')),
        intervals: list('intervals'),
      ),
      'ledger' => LedgerEntry(
        id: LedgerId(text('id')),
        operationId: OperationId(text('operation')),
        itemId: ItemId(text('item')),
        itemRevision: revision(),
        sessionId: m['session'] == null ? null : SessionId(text('session')),
        timestamp: child('at'),
        dimension: child('dimension'),
        delta: number('delta'),
      ),
      'virtualDimension' => VirtualCurrencyDimension(
        VirtualCurrency.values.byName(text('currency')),
      ),
      'timeDimension' => const TimeDimension(),
      'budgetDimension' => BudgetDimension(
        currency(text('currency'), number('digits')),
      ),
      'wallet' => WalletProjection(
        revision: revision(),
        balances: child('balances'),
      ),
      'balance' => AwardBalance(
        awardId: ItemId(text('id')),
        revision: revision(),
        time: time('time'),
        budget: optional('budget'),
      ),
      'remainder' => QuestAccrualRemainder(
        questId: ItemId(text('id')),
        currency: VirtualCurrency.values.byName(text('currency')),
        remainder: AccrualRemainder(number('value')),
      ),
      'goalRevision' => DailyGoalRevision(
        questId: ItemId(text('id')),
        revision: revision(),
        effectiveFrom: parseDay(text('day')),
        zone: ReportingZone(text('zone')),
        goal: optional('goal'),
      ),
      'achievement' => DailyAchievement(
        questId: ItemId(text('id')),
        day: parseDay(text('day')),
        goalRevision: revision(),
        operationId: OperationId(text('operation')),
        awardedAt: child('at'),
        bonus: child('bonus'),
      ),
      'settings' => AppSettings(
        revision: revision(),
        reportingZone: ReportingZone(text('zone')),
      ),
      'schema' => SchemaVersion(number('value')),
      'notification' => NotificationIntent(
        sessionId: SessionId(text('id')),
        sessionRevision: revision(),
        completionId: CompletionId(text('completion')),
        deadlineUtc: deadline(),
        completionChimeHandled: m['handled'] as bool,
      ),
      'economy' => EconomicState(
        operationId: OperationId(text('operation')),
        wallet: child('wallet'),
        awards: list('awards'),
        activeSession: optional('session'),
        entries: list('entries'),
        achievements: list('achievements'),
      ),
      'sessionMutation' => SessionMutation(
        session: child('session'),
        economy: child('economy'),
        notificationIntent: child('intent'),
      ),
      'restoreReceipt' => RestoreReceipt(
        operationId: OperationId(text('operation')),
        sourceSha256: text('sha256'),
        schemaVersion: child('schema'),
        settings: child('settings'),
      ),
      'items' => list<Item>('items'),
      'bool' => m['value'] as bool,
      _ => throw const FormatException('Unsupported stored record type'),
    };
  }

  BudgetCurrency currency(String code, int digits) {
    final result = BudgetCurrency.fromMetadata(code, currencies);
    if (result.minorDigits != digits) {
      throw const FormatException(
        'Persisted budget precision differs from metadata',
      );
    }
    return result;
  }

  static DateTime utc(int milliseconds) =>
      DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  static String day(DayKey value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  static DayKey parseDay(String value) {
    final parts = value.split('-').map(int.parse).toList();
    if (parts.length != 3) throw const FormatException('Invalid stored day');
    return DayKey(parts[0], parts[1], parts[2]);
  }
}
