import 'dart:typed_data';

import 'items.dart';
import 'records.dart';
import 'result.dart';
import 'values.dart';

/// Serialize all mutations across repositories in the adapter. A success is
/// durable, includes all economic effects, and is replayed for its operation ID.
/// Reusing an ID with different arguments returns InvalidInput without effects.
/// Implementations map value-validation errors to Failure before writing.
abstract interface class ItemRepository {
  Future<Result<Item?>> getItem(ItemId id);
  Stream<List<Item>> watchItems();
  Stream<List<Group>> watchGroups();

  /// Null expectedRevision creates a new item; otherwise compare inside the
  /// transaction. The adapter assigns the next revision and checks history.
  /// Session snapshots are immutable. Goal edits after activity apply tomorrow.
  Future<Result<Item>> saveItem({
    required OperationId operationId,
    required Item item,
    required Revision? expectedRevision,
  });
  Future<Result<Item>> archiveItem({
    required OperationId operationId,
    required ItemId itemId,
    required Revision expectedRevision,
  });
  Future<Result<Group>> saveGroup({
    required OperationId operationId,
    required Group group,
    required Revision? expectedRevision,
  });

  /// Reassign members to Ungrouped atomically, retaining their order and history.
  Future<Result<List<Item>>> removeGroup({
    required OperationId operationId,
    required GroupId groupId,
    required Revision expectedRevision,
  });
}

enum SessionConflictChoice { cancel, endCurrentAndContinue }

/// Returned after session changes, purchase, and expense as one committed state.
final class EconomicState {
  EconomicState({
    required this.operationId,
    required this.wallet,
    required List<AwardBalance> awards,
    required this.activeSession,
    required List<LedgerEntry> entries,
    required List<DailyAchievement> achievements,
  }) : awards = List.unmodifiable(awards),
       entries = List.unmodifiable(entries),
       achievements = List.unmodifiable(achievements);
  final OperationId operationId;
  final WalletProjection wallet;
  final List<AwardBalance> awards;
  final Session? activeSession;
  final List<LedgerEntry> entries;
  final List<DailyAchievement> achievements;
}

final class SessionMutation {
  const SessionMutation({
    required this.session,
    required this.economy,
    required this.notificationIntent,
  });
  final Session session;
  final EconomicState economy;
  final NotificationIntent notificationIntent;
}

abstract interface class SessionRepository {
  Future<Result<Session?>> getSession(SessionId id);
  Stream<Session?> watchActiveSession();

  /// Award duration comes from its pooled allowance. Paused sessions hold slot.
  /// An explicit replacement settles the old session in this same transaction.
  Future<Result<SessionMutation>> startSession({
    required OperationId operationId,
    required ItemId itemId,
    required Revision expectedItemRevision,
    required SessionConflictChoice conflictChoice,
  });
  Future<Result<SessionMutation>> pauseSession({
    required OperationId operationId,
    required SessionId sessionId,
    required Revision expectedRevision,
  });
  Future<Result<SessionMutation>> resumeSession({
    required OperationId operationId,
    required SessionId sessionId,
    required Revision expectedRevision,
  });
  Future<Result<SessionMutation>> endSession({
    required OperationId operationId,
    required SessionId sessionId,
    required Revision expectedRevision,
  });

  /// Reconcile deadline/boot/monotonic anchors; cap progress and settle once.
  Future<Result<SessionMutation>> reconcileSession({
    required OperationId operationId,
    required SessionId sessionId,
  });
}

final class PurchaseQuantity {
  PurchaseQuantity(this.value) {
    if (value <= 0) {
      throw const InvalidInput('quantity', 'Expected positive whole packs');
    }
  }
  final int value;
}

final class RedemptionPreview {
  const RedemptionPreview({
    required this.awardId,
    required this.itemRevision,
    required this.quantity,
    required this.totalPrice,
    required this.timeGrant,
    required this.budgetGrant,
    required this.walletAfter,
    required this.maximumAffordableQuantity,
  });
  final ItemId awardId;
  final Revision itemRevision;
  final PurchaseQuantity quantity;
  final CurrencyAmounts totalPrice;
  final Milliseconds? timeGrant;
  final BudgetAmount? budgetGrant;
  final CurrencyAmounts walletAfter;
  final int maximumAffordableQuantity;
}

/// Pure preview; redemption repeats these checks on current transactional state.
Result<RedemptionPreview> previewRedemption({
  required Item award,
  required PurchaseQuantity quantity,
  required CurrencyAmounts wallet,
}) {
  final config = award.configuration;
  if (award.archived || config is! AwardConfiguration) {
    return const Failure(InvalidInput('award', 'Not purchasable'));
  }
  try {
    final price = config.price.times(quantity.value);
    final coinsShort = price.coins.units > wallet.coins.units;
    final gemsShort = price.gems.units > wallet.gems.units;
    if (coinsShort || gemsShort) {
      return Failure(InsufficientFunds(coins: coinsShort, gems: gemsShort));
    }
    var maximum = maxStoredInteger;
    for (final pair in [
      (wallet.coins.units, config.price.coins.units),
      (wallet.gems.units, config.price.gems.units),
    ]) {
      if (pair.$2 != 0 && pair.$1 ~/ pair.$2 < maximum) {
        maximum = pair.$1 ~/ pair.$2;
      }
    }
    return Success(
      RedemptionPreview(
        awardId: award.id,
        itemRevision: award.revision,
        quantity: quantity,
        totalPrice: price,
        timeGrant: config.timeGrant?.times(quantity.value),
        budgetGrant: config.budgetGrant?.times(quantity.value),
        walletAfter: CurrencyAmounts(
          coins: wallet.coins - price.coins,
          gems: wallet.gems - price.gems,
        ),
        maximumAffordableQuantity: maximum,
      ),
    );
  } on DomainError catch (error) {
    return Failure(error);
  }
}

abstract interface class EconomyRepository {
  Stream<WalletProjection> watchWallet();
  Stream<List<AwardBalance>> watchAwards();
  Future<Result<RedemptionPreview>> previewAward({
    required ItemId awardId,
    required PurchaseQuantity quantity,
  });

  /// Validate revision, both prices, total grants and resulting pooled balances
  /// with checked arithmetic; duplicates return the original committed result.
  Future<Result<EconomicState>> redeemAward({
    required OperationId operationId,
    required ItemId awardId,
    required Revision expectedRevision,
    required PurchaseQuantity quantity,
  });

  /// Expense must be positive, same ISO currency/precision, and within balance.
  /// A slot conflict changes nothing unless explicitly ended by the user.
  Future<Result<EconomicState>> recordExpense({
    required OperationId operationId,
    required ItemId awardId,
    required Revision expectedBalanceRevision,
    required BudgetAmount expense,
    required SessionConflictChoice conflictChoice,
  });
}

enum StatsPeriod { daily, weekly, monthly, yearly }

enum StatsCategory { all, quests, awards, currencies, item }

enum StatsMetric {
  questTime,
  awardTime,
  budgetSpent,
  coinsEarned,
  coinsSpent,
  gemsEarned,
  gemsSpent,
  dailyGoalCompletion,
}

final class StatsQuery {
  StatsQuery({
    required this.period,
    required this.anchor,
    required this.category,
    required this.metric,
    this.itemId,
    this.budgetCurrency,
  }) {
    if ((category == StatsCategory.item) != (itemId != null)) {
      throw const InvalidInput('filter', 'Individual filter requires item');
    }
    if ((metric == StatsMetric.budgetSpent) != (budgetCurrency != null)) {
      throw const InvalidInput('metric', 'Budget requires one currency');
    }
    final compatible = switch (category) {
      StatsCategory.all || StatsCategory.item => true,
      StatsCategory.quests =>
        metric == StatsMetric.questTime ||
            metric == StatsMetric.dailyGoalCompletion ||
            metric == StatsMetric.coinsEarned ||
            metric == StatsMetric.gemsEarned,
      StatsCategory.awards =>
        metric == StatsMetric.awardTime ||
            metric == StatsMetric.budgetSpent ||
            metric == StatsMetric.coinsSpent ||
            metric == StatsMetric.gemsSpent,
      StatsCategory.currencies =>
        metric == StatsMetric.coinsEarned ||
            metric == StatsMetric.coinsSpent ||
            metric == StatsMetric.gemsEarned ||
            metric == StatsMetric.gemsSpent,
    };
    if (!compatible) {
      throw const InvalidInput('metric', 'Incompatible category');
    }
  }
  final StatsPeriod period;
  final DayKey anchor;
  final StatsCategory category;
  final StatsMetric metric;
  final ItemId? itemId;
  final BudgetCurrency? budgetCurrency;
}

final class StatsBucket {
  StatsBucket({required this.start, required this.end, required int value})
    : value = nonNegative(value, 'bucket') {
    if (!start.isUtc || !end.isUtc || !end.isAfter(start)) {
      throw const InvalidInput('bucket', 'Expected positive UTC interval');
    }
  }
  final DateTime start;
  final DateTime end;

  /// Milliseconds, minor units, millionths, or count, as identified by query.
  final int value;
}

abstract interface class StatsRepository {
  /// Frozen event assignments; Monday weeks; zero-filled calendar buckets.
  /// The adapter checks individual item/metric compatibility, including archive.
  Future<Result<List<StatsBucket>>> query(StatsQuery query);
}

abstract interface class SettingsRepository {
  Future<Result<AppSettings>> getSettings();

  /// Validate IANA membership and apply zone only to new operations/sessions.
  Future<Result<AppSettings>> saveSettings({
    required OperationId operationId,
    required Revision expectedRevision,
    required ReportingZone reportingZone,
  });
}

abstract interface class Clock {
  ClockReading now();
}

/// Calendar rules live behind a port so domain tests can supply DST boundaries.
abstract interface class ReportingCalendar {
  bool supports(ReportingZone zone);
  EventTime assign(DateTime utc, ReportingZone zone);
  DateTime nextMidnight(EventTime time);
}

enum NotificationPermission { notDetermined, granted, denied, restricted }

abstract interface class NotificationScheduler {
  Future<NotificationPermission> permission();
  Future<NotificationPermission> requestPermission({
    required OperationId operationId,
  });

  /// Idempotently replace/cancel stable IDs from persisted intents and remove
  /// stale requests. Honor completionChimeHandled and platform sound settings.
  Future<Result<NotificationPermission>> reconcile({
    required OperationId operationId,
    required List<NotificationIntent> intents,
  });
  Future<Result<bool>> openSystemSettings({required OperationId operationId});
}

final class BackupVersion {
  BackupVersion(this.value) {
    if (value < 1) {
      throw const InvalidInput('backupVersion', 'Must be positive');
    }
  }
  final int value;
}

final class BackupFile {
  BackupFile(List<int> bytes)
    : _bytes = Uint8List.fromList(bytes).asUnmodifiableView() {
    if (bytes.any((value) => value < 0 || value > 255)) {
      throw const InvalidInput('backup', 'Expected bytes');
    }
  }
  final Uint8List _bytes;
  Uint8List get bytes => _bytes;
}

/// Validation identifies this exact file by digest; confirmation cannot silently
/// substitute another source. This is a preview, not a promise of valid contents.
final class BackupPreview {
  BackupPreview({
    required this.version,
    required this.createdUtc,
    required String sha256,
    required Map<String, int> recordCounts,
  }) : sha256 = sha256,
       recordCounts = Map.unmodifiable(recordCounts) {
    if (!createdUtc.isUtc ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) ||
        recordCounts.values.any((count) => count < 0)) {
      throw const InvalidInput('backupPreview', 'Invalid metadata');
    }
  }
  final BackupVersion version;
  final DateTime createdUtc;
  final String sha256;
  final Map<String, int> recordCounts;
}

final class RestoreConfirmation {
  const RestoreConfirmation({
    required this.preview,
    required this.expectedSettingsRevision,
  });
  final BackupPreview preview;
  final Revision expectedSettingsRevision;
}

final class RestoreReceipt {
  const RestoreReceipt({
    required this.operationId,
    required this.sourceSha256,
    required this.schemaVersion,
    required this.settings,
  });
  final OperationId operationId;
  final String sourceSha256;
  final SchemaVersion schemaVersion;
  final AppSettings settings;
}

abstract interface class BackupRepository {
  /// No active session. Export is unencrypted; sharing is a separate UI action.
  Future<Result<BackupFile>> exportBackup({required OperationId operationId});

  /// Size/range/relationship/idempotency/ledger checks use a temporary database.
  Future<Result<BackupPreview>> inspectBackup(BackupFile file);

  /// Requires explicit in-app replacement confirmation. Revalidate the digest,
  /// preserve a safety copy, swap atomically, cancel notifications, then reopen.
  /// Never restart imported sessions. Any failure retains usable original data.
  Future<Result<RestoreReceipt>> restoreBackup({
    required OperationId operationId,
    required BackupFile file,
    required RestoreConfirmation confirmation,
  });
}
