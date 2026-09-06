import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';

String uuid(int n) =>
    '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
const metadata = TestCurrencies();
final zone = ReportingZone('Etc/UTC');
final now = DateTime.utc(2026, 1, 15, 12);
final event = EventTime(
  utc: now,
  day: DayKey(2026, 1, 15),
  zone: zone,
  offsetSeconds: 0,
);
final settings = AppSettings(revision: Revision(1), reportingZone: zone);

class TestCurrencies implements CurrencyMetadata {
  const TestCurrencies();
  @override
  String get version => 'synthetic-fixture-v1';
  @override
  int? minorDigitsFor(String code) => switch (code) {
    'USD' => 2,
    'JPY' => 0,
    _ => null,
  };
}

CurrencyAmounts amounts(int coins, [int gems = 0]) =>
    CurrencyAmounts(coins: MicroAmount(coins), gems: MicroAmount(gems));
Item quest({
  int n = 1,
  int revision = 1,
  GroupId? groupId,
  String name = 'Synthetic Quest',
}) => Item(
  id: ItemId(uuid(n)),
  revision: Revision(revision),
  name: name,
  iconKey: 'gamepad',
  colorArgb: 0xff883366,
  groupId: groupId,
  order: 0,
  archived: false,
  configuration: QuestConfiguration(
    duration: Milliseconds.seconds(60),
    ratesPerHour: amounts(1000000),
    dailyGoal: DailyGoal(target: Milliseconds.seconds(60), bonus: amounts(10)),
  ),
);
Item award({int n = 2}) => Item(
  id: ItemId(uuid(n)),
  revision: Revision(1),
  name: 'Synthetic Combined Award',
  iconKey: 'gamepad',
  colorArgb: 0xff883366,
  groupId: null,
  order: 1,
  archived: false,
  configuration: AwardConfiguration(
    packName: 'Pack',
    price: amounts(20),
    timeGrant: Milliseconds.seconds(60),
    budgetGrant: BudgetAmount(
      BudgetCurrency.fromMetadata('USD', metadata),
      1000,
    ),
  ),
);
Group group({int n = 3, int revision = 1, String name = 'Synthetic Group'}) =>
    Group(
      id: GroupId(uuid(n)),
      revision: Revision(revision),
      name: name,
      order: 0,
    );
Session session(
  Item item, {
  int n = 4,
  SessionStatus status = SessionStatus.running,
  int revision = 1,
}) => Session(
  id: SessionId(uuid(n)),
  revision: Revision(revision),
  itemSnapshot: item,
  status: status,
  zone: zone,
  startedAt: ClockReading(
    utc: now,
    bootId: 'fixture-boot',
    monotonic: Milliseconds(1000),
  ),
  checkpoint: ClockReading(
    utc: now.add(const Duration(seconds: 10)),
    bootId: 'fixture-boot',
    monotonic: Milliseconds(11000),
  ),
  duration: Milliseconds(60000),
  settled: Milliseconds(status == SessionStatus.completed ? 60000 : 10000),
  deadlineUtc: status == SessionStatus.running
      ? now.add(const Duration(minutes: 1))
      : null,
  completionId: CompletionId(uuid(n + 100)),
  intervals: [
    ActiveInterval(
      startedAt: ClockReading(
        utc: now,
        bootId: 'fixture-boot',
        monotonic: Milliseconds(1000),
      ),
      endedAt: ClockReading(
        utc: now.add(const Duration(seconds: 10)),
        bootId: 'fixture-boot',
        monotonic: Milliseconds(11000),
      ),
      active: Milliseconds(10000),
      assignment: event,
    ),
  ],
);
Operation<T> operation<T extends Object>(T result, {int n = 5}) => Operation(
  id: OperationId(uuid(n)),
  kind: OperationKind.reconcileSession,
  committedAt: event,
  requestFingerprint: 'synthetic-request-$n',
  committedResult: result,
);
LedgerEntry entry(
  Item item,
  LedgerDimension dimension,
  int delta, {
  int n = 6,
  int op = 5,
  SessionId? sessionId,
}) => LedgerEntry(
  id: LedgerId(uuid(n)),
  operationId: OperationId(uuid(op)),
  itemId: item.id,
  itemRevision: item.revision,
  sessionId: sessionId,
  timestamp: event,
  dimension: dimension,
  delta: delta,
);
T success<T>(Result<T> result) {
  if (result is Success<T>) return result.value;
  throw StateError('Expected success, got ${(result as Failure).error}');
}

Future<void> seed(StoreTransaction tx) async {
  final g = group();
  final q = quest(groupId: g.id);
  final a = award();
  final s = session(q);
  await tx.putGroup(g);
  await tx.putItem(ItemRevision(snapshot: q, recordedAt: event));
  await tx.putItem(ItemRevision(snapshot: a, recordedAt: event));
  await tx.putSession(s);
  await tx.putNotificationIntent(
    NotificationIntent(
      sessionId: s.id,
      sessionRevision: s.revision,
      completionId: s.completionId,
      deadlineUtc: s.deadlineUtc,
      completionChimeHandled: false,
    ),
  );
  await tx.putRemainder(
    QuestAccrualRemainder(
      questId: q.id,
      currency: VirtualCurrency.coins,
      remainder: AccrualRemainder(1234),
    ),
  );
  await tx.insertGoal(
    DailyGoalRevision(
      questId: q.id,
      revision: Revision(1),
      effectiveFrom: event.day,
      zone: zone,
      goal: (q.configuration as QuestConfiguration).dailyGoal,
    ),
  );
  final achievement = DailyAchievement(
    questId: q.id,
    day: event.day,
    goalRevision: Revision(1),
    operationId: OperationId(uuid(5)),
    awardedAt: event,
    bonus: amounts(10),
  );
  await tx.insertAchievement(achievement);
  final wallet = WalletProjection(
    revision: Revision(2),
    balances: amounts(100, 2),
  );
  final balance = AwardBalance(
    awardId: a.id,
    revision: Revision(1),
    time: Milliseconds(60000),
    budget: BudgetAmount(BudgetCurrency.fromMetadata('USD', metadata), 1000),
  );
  final entries = [
    entry(q, const VirtualCurrencyDimension(VirtualCurrency.coins), 100),
    entry(q, const VirtualCurrencyDimension(VirtualCurrency.gems), 2, n: 7),
    entry(a, const TimeDimension(), 60000, n: 8),
    entry(a, BudgetDimension(balance.budget!.currency), 1000, n: 9),
  ];
  for (final e in entries) {
    await tx.insertLedger(e);
  }
  await tx.putWallet(wallet);
  await tx.putAward(balance);
  await tx.insertOperation(
    operation(
      EconomicState(
        operationId: OperationId(uuid(5)),
        wallet: wallet,
        awards: [balance],
        activeSession: s,
        entries: entries,
        achievements: [achievement],
      ),
    ),
  );
}
