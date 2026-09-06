import 'items.dart';
import 'result.dart';
import 'values.dart';

enum SessionStatus { running, paused, completed, ended }

final class ClockReading {
  ClockReading({
    required this.utc,
    required String bootId,
    required this.monotonic,
  }) : bootId = nonEmpty(bootId, 'bootId') {
    if (!utc.isUtc) throw const InvalidInput('clock', 'Expected UTC wall time');
  }
  final DateTime utc;
  final String bootId;
  final Milliseconds monotonic;
}

final class ActiveInterval {
  ActiveInterval({
    required this.startedAt,
    required this.endedAt,
    required this.active,
    required this.assignment,
  }) {
    if (endedAt.utc.isBefore(startedAt.utc) &&
        endedAt.bootId != startedAt.bootId) {
      throw const InvalidInput('interval', 'Unreconciled wall-clock reversal');
    }
    if (startedAt.bootId == endedAt.bootId &&
        endedAt.monotonic.value < startedAt.monotonic.value) {
      throw const InvalidInput('interval', 'Negative monotonic interval');
    }
  }
  final ClockReading startedAt;
  final ClockReading endedAt;
  final Milliseconds active;

  /// Intervals are split by the timezone adapter at actual local midnight.
  final EventTime assignment;
}

final class Session {
  Session({
    required this.id,
    required this.revision,
    required this.itemSnapshot,
    required this.status,
    required this.zone,
    required this.startedAt,
    required this.checkpoint,
    required this.duration,
    required this.settled,
    required this.deadlineUtc,
    required this.completionId,
    required List<ActiveInterval> intervals,
  }) : intervals = List.unmodifiable(intervals) {
    if (duration.value == 0 || settled.value > duration.value) {
      throw const InvalidInput(
        'session',
        'Invalid duration or settled progress',
      );
    }
    if ((status == SessionStatus.running) != (deadlineUtc != null) ||
        (deadlineUtc != null && !deadlineUtc!.isUtc)) {
      throw const InvalidInput(
        'deadline',
        'Only running sessions have a UTC deadline',
      );
    }
    if (status == SessionStatus.completed && settled != duration) {
      throw const InvalidInput(
        'session',
        'Completion must settle full duration',
      );
    }
    if (itemSnapshot.type == ItemType.award &&
        (itemSnapshot.configuration as AwardConfiguration).timeGrant == null) {
      throw const InvalidInput('session', 'Award has no time dimension');
    }
  }
  final SessionId id;
  final Revision revision;
  final Item itemSnapshot;
  final SessionStatus status;
  final ReportingZone zone;
  final ClockReading startedAt;
  final ClockReading checkpoint;
  final Milliseconds duration;
  final Milliseconds settled;
  final DateTime? deadlineUtc;
  final CompletionId completionId;
  final List<ActiveInterval> intervals;
  bool get occupiesSlot =>
      status == SessionStatus.running || status == SessionStatus.paused;
}

enum OperationKind {
  saveItem,
  archiveItem,
  saveGroup,
  removeGroup,
  startSession,
  pauseSession,
  resumeSession,
  endSession,
  reconcileSession,
  redeemAward,
  recordExpense,
  saveSettings,
  exportBackup,
  restoreBackup,
  reconcileNotifications,
}

final class Operation<T extends Object> {
  const Operation({
    required this.id,
    required this.kind,
    required this.committedAt,
    required this.requestFingerprint,
    required this.committedResult,
  });
  final OperationId id;
  final OperationKind kind;
  final EventTime committedAt;

  /// Canonical request digest detects conflicting reuse of an operation ID.
  final String requestFingerprint;

  /// Persist the original immutable command result for exact duplicate replay.
  final T committedResult;
}

enum VirtualCurrency { coins, gems }

sealed class LedgerDimension {
  const LedgerDimension();
}

final class VirtualCurrencyDimension extends LedgerDimension {
  const VirtualCurrencyDimension(this.currency);
  final VirtualCurrency currency;
}

final class TimeDimension extends LedgerDimension {
  const TimeDimension();
}

final class BudgetDimension extends LedgerDimension {
  const BudgetDimension(this.currency);
  final BudgetCurrency currency;
}

final class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.operationId,
    required this.itemId,
    required this.itemRevision,
    required this.sessionId,
    required this.timestamp,
    required this.dimension,
    required this.delta,
  });
  final LedgerId id;
  final OperationId operationId;
  final ItemId itemId;
  final Revision itemRevision;
  final SessionId? sessionId;
  final EventTime timestamp;
  final LedgerDimension dimension;

  /// Signed millionths, milliseconds, or minor units according to dimension.
  final int delta;
}

final class WalletProjection {
  const WalletProjection({required this.revision, required this.balances});
  final Revision revision;
  final CurrencyAmounts balances;
}

final class AwardBalance {
  AwardBalance({
    required this.awardId,
    required this.revision,
    this.time,
    this.budget,
  }) {
    if (time == null && budget == null) {
      throw const InvalidInput('allowance', 'Missing dimensions');
    }
  }
  final ItemId awardId;
  final Revision revision;

  /// Null means an absent dimension; zero retains its declared dimension.
  final Milliseconds? time;
  final BudgetAmount? budget;
  bool get isExhausted =>
      (time?.value ?? 0) == 0 && (budget?.minorUnits ?? 0) == 0;
}

final class QuestAccrualRemainder {
  const QuestAccrualRemainder({
    required this.questId,
    required this.currency,
    required this.remainder,
  });
  final ItemId questId;
  final VirtualCurrency currency;
  final AccrualRemainder remainder;
}

final class DailyAchievement {
  const DailyAchievement({
    required this.questId,
    required this.day,
    required this.goalRevision,
    required this.operationId,
    required this.awardedAt,
    required this.bonus,
  });
  final ItemId questId;

  /// Unique with questId, independent of zone and goal revision.
  final DayKey day;
  final Revision goalRevision;
  final OperationId operationId;
  final EventTime awardedAt;
  final CurrencyAmounts bonus;
}

final class AppSettings {
  const AppSettings({required this.revision, required this.reportingZone});
  final Revision revision;
  final ReportingZone reportingZone;
}

final class SchemaVersion {
  SchemaVersion(this.value) {
    if (value < 1) {
      throw const InvalidInput('schemaVersion', 'Must be positive');
    }
  }
  final int value;
}

final class NotificationIntent {
  NotificationIntent({
    required this.sessionId,
    required this.sessionRevision,
    required this.completionId,
    required this.deadlineUtc,
    required this.completionChimeHandled,
  }) {
    if (deadlineUtc != null && !deadlineUtc!.isUtc) {
      throw const InvalidInput('notification', 'Expected UTC deadline');
    }
  }
  final SessionId sessionId;
  final Revision sessionRevision;
  final CompletionId completionId;

  /// Null explicitly cancels a previously scheduled notification.
  final DateTime? deadlineUtc;

  /// Persist before acknowledging foreground playback; do not replay on restart.
  final bool completionChimeHandled;
  String get stableIdentifier => sessionId.value;
}
