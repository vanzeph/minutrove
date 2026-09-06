import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/domain.dart';
import 'command_coordinator.dart';
import 'sqlite_store.dart';

/// Shares the live store's queue with item, purchase and expense mutations.
final class SqliteSessionRepository implements SessionRepository {
  const SqliteSessionRepository({
    required this.store,
    required this.clock,
    required this.calendar,
  });

  final SqliteStore store;
  final Clock clock;
  final ReportingCalendar calendar;

  @override
  Future<Result<Session?>> getSession(SessionId id) =>
      store.read((records) => records.session(id));

  @override
  Stream<Session?> watchActiveSession() =>
      store.watch((records) => records.activeSession());

  Future<Result<SessionMutation>> _execute({
    required OperationId operationId,
    required OperationKind kind,
    required Map<String, Object?> arguments,
    required Future<Session> Function(CommandTransaction, ClockReading) apply,
    SessionId? sessionId,
  }) {
    late ClockReading reading;
    return CommandCoordinator(store).execute(
      operationId: operationId,
      request: CommandRequest(kind: kind, arguments: arguments),
      committedAt: (records) async {
        reading = clock.now();
        final session = sessionId == null
            ? null
            : await records.session(sessionId);
        final zone = session?.zone ?? (await records.settings()).reportingZone;
        if (!calendar.supports(zone)) {
          throw const InvalidInput(
            'reportingZone',
            'Unsupported reporting zone',
          );
        }
        return calendar.assign(reading.utc, zone);
      },
      action: (command) async {
        final session = await apply(command, reading);
        final intent = (await command.records.notificationIntents())
            .singleWhere((value) => value.sessionId == session.id);
        return SessionMutation(
          session: session,
          economy: await command.economicState(),
          notificationIntent: intent,
        );
      },
    );
  }

  @override
  Future<Result<SessionMutation>> startSession({
    required OperationId operationId,
    required ItemId itemId,
    required Revision expectedItemRevision,
    required SessionConflictChoice conflictChoice,
  }) => _execute(
    operationId: operationId,
    kind: OperationKind.startSession,
    arguments: {
      'itemId': itemId.value,
      'expectedItemRevision': expectedItemRevision.value,
      'conflictChoice': conflictChoice.name,
    },
    apply: (command, reading) async {
      final item = await command.requireItem(itemId, expectedItemRevision);
      final active = await command.records.activeSession();
      // A fresh repeated tap never replaces or resumes the same active item.
      if (active?.itemSnapshot.id == itemId) return active!;
      if (active != null && conflictChoice == SessionConflictChoice.cancel) {
        throw const ActiveSessionConflict();
      }
      final config = item.configuration;
      final duration = switch (config) {
        QuestConfiguration(:final duration) when !item.archived => duration,
        AwardConfiguration(:final timeGrant) when timeGrant != null =>
          (await command.records.award(itemId))?.time ?? Milliseconds(0),
        _ => throw const InvalidInput('item', 'No startable time session'),
      };
      if (duration.value == 0) throw const AllowanceExceeded();
      final zone = (await command.records.settings()).reportingZone;
      final session = Session(
        // Operation IDs are globally unique; replays never allocate new IDs.
        id: SessionId(operationId.value),
        revision: Revision(1),
        itemSnapshot: item,
        status: SessionStatus.running,
        zone: zone,
        startedAt: reading,
        checkpoint: reading,
        duration: duration,
        settled: Milliseconds(0),
        deadlineUtc: sessionDeadline(reading.utc, duration),
        completionId: CompletionId(operationId.value),
        intervals: const [],
      );
      if (active != null) {
        await SessionSettlement(calendar).apply(
          command: command,
          session: active,
          reading: reading,
          action: SessionAction.end,
        );
      }
      await command.records.putSession(session);
      await command.records.putNotificationIntent(_intent(session, false));
      return session;
    },
  );

  Future<Result<SessionMutation>> _change({
    required OperationId operationId,
    required SessionId sessionId,
    required Revision? expectedRevision,
    required OperationKind kind,
    required SessionAction action,
  }) => _execute(
    operationId: operationId,
    kind: kind,
    sessionId: sessionId,
    arguments: {
      'sessionId': sessionId.value,
      if (expectedRevision != null) 'expectedRevision': expectedRevision.value,
    },
    apply: (command, reading) async {
      final session = expectedRevision == null
          ? await command.records.session(sessionId)
          : await command.requireSession(sessionId, expectedRevision);
      if (session == null) throw const NotFound();
      return SessionSettlement(calendar).apply(
        command: command,
        session: session,
        reading: reading,
        action: action,
      );
    },
  );

  @override
  Future<Result<SessionMutation>> pauseSession({
    required OperationId operationId,
    required SessionId sessionId,
    required Revision expectedRevision,
  }) => _change(
    operationId: operationId,
    sessionId: sessionId,
    expectedRevision: expectedRevision,
    kind: OperationKind.pauseSession,
    action: SessionAction.pause,
  );

  @override
  Future<Result<SessionMutation>> resumeSession({
    required OperationId operationId,
    required SessionId sessionId,
    required Revision expectedRevision,
  }) => _change(
    operationId: operationId,
    sessionId: sessionId,
    expectedRevision: expectedRevision,
    kind: OperationKind.resumeSession,
    action: SessionAction.resume,
  );

  @override
  Future<Result<SessionMutation>> endSession({
    required OperationId operationId,
    required SessionId sessionId,
    required Revision expectedRevision,
  }) => _change(
    operationId: operationId,
    sessionId: sessionId,
    expectedRevision: expectedRevision,
    kind: OperationKind.endSession,
    action: SessionAction.end,
  );

  @override
  Future<Result<SessionMutation>> reconcileSession({
    required OperationId operationId,
    required SessionId sessionId,
  }) => _change(
    operationId: operationId,
    sessionId: sessionId,
    expectedRevision: null,
    kind: OperationKind.reconcileSession,
    action: SessionAction.reconcile,
  );
}

/// Reusable inside an existing command, including an explicit expense conflict
/// replacement. Never calls another repository or opens a nested transaction.
final class SessionSettlement {
  const SessionSettlement(this.calendar);
  final ReportingCalendar calendar;

  Future<Session> apply({
    required CommandTransaction command,
    required Session session,
    required ClockReading reading,
    required SessionAction action,
  }) async {
    final progress = advanceSession(
      session: session,
      action: action,
      now: reading,
      calendar: calendar,
    );
    final updated = progress.session;
    if (identical(session, updated)) return session;
    final records = command.records;
    await records.putSession(updated);
    final item = session.itemSnapshot;
    final entries = <LedgerEntry>[];
    final goals = item.type == ItemType.quest
        ? await records.goals(item.id)
        : <DailyGoalRevision>[];
    final achieved = item.type == ItemType.quest
        ? (await records.achievements(questId: item.id))
              .map((a) => a.day)
              .toSet()
        : <DayKey>{};
    final dailyActive = <DayKey, BigInt>{};
    var ordinal = 0;
    void post(
      ActiveInterval interval,
      LedgerDimension dimension,
      int delta, {
      EventTime? timestamp,
    }) {
      if (delta == 0) return;
      entries.add(
        LedgerEntry(
          id: _ledgerId(command.operationId, session.id, ordinal++),
          operationId: command.operationId,
          itemId: item.id,
          itemRevision: item.revision,
          sessionId: session.id,
          timestamp: timestamp ?? interval.assignment,
          dimension: dimension,
          delta: delta,
        ),
      );
    }

    for (final interval in progress.addedIntervals) {
      post(
        interval,
        const TimeDimension(),
        item.type == ItemType.quest
            ? interval.active.value
            : -interval.active.value,
      );
      final config = item.configuration;
      if (config is QuestConfiguration) {
        for (final currency in VirtualCurrency.values) {
          final old = await records.remainder(item.id, currency);
          final earned = accrue(
            perHour: currency == VirtualCurrency.coins
                ? config.ratesPerHour.coins
                : config.ratesPerHour.gems,
            active: interval.active,
            remainder: old?.remainder ?? AccrualRemainder(0),
          );
          await records.putRemainder(
            QuestAccrualRemainder(
              questId: item.id,
              currency: currency,
              remainder: earned.remainder,
            ),
          );
          post(
            interval,
            VirtualCurrencyDimension(currency),
            earned.amount.units,
          );
        }
        final day = interval.assignment.day;
        final prior =
            dailyActive[day] ?? await records.questActiveOn(item.id, day);
        dailyActive[day] = prior + BigInt.from(interval.active.value);
        final effective = effectiveDailyGoal(goals, day);
        final crossing = dailyGoalCrossing(
          goal: effective?.goal,
          priorActive: prior,
          added: interval.active,
        );
        if (crossing != null && achieved.add(day)) {
          var instant = interval.startedAt.utc.add(
            Duration(milliseconds: crossing),
          );
          // Intervals are half-open. A goal met exactly at midnight belongs to
          // the day whose final active millisecond earned it, not the new day.
          if (calendar.assign(instant, session.zone).day != day) {
            instant = instant.subtract(const Duration(milliseconds: 1));
          }
          final awardedAt = calendar.assign(instant, session.zone);
          final bonus = effective!.goal!.bonus;
          await records.insertAchievement(
            DailyAchievement(
              questId: item.id,
              day: day,
              goalRevision: effective.revision,
              operationId: command.operationId,
              awardedAt: awardedAt,
              bonus: bonus,
            ),
          );
          post(
            interval,
            const VirtualCurrencyDimension(VirtualCurrency.coins),
            bonus.coins.units,
            timestamp: awardedAt,
          );
          post(
            interval,
            const VirtualCurrencyDimension(VirtualCurrency.gems),
            bonus.gems.units,
            timestamp: awardedAt,
          );
        }
      }
    }
    await command.postLedger(entries);
    final oldIntent = (await records.notificationIntents())
        .where((value) => value.sessionId == session.id)
        .firstOrNull;
    await records.putNotificationIntent(
      _intent(updated, oldIntent?.completionChimeHandled ?? false),
    );
    return updated;
  }
}

NotificationIntent _intent(Session session, bool handled) => NotificationIntent(
  sessionId: session.id,
  sessionRevision: session.revision,
  completionId: session.completionId,
  deadlineUtc: session.deadlineUtc,
  completionChimeHandled: handled,
);

LedgerId _ledgerId(OperationId operation, SessionId session, int ordinal) {
  final hex = sha256
      .convert(
        utf8.encode(
          'session-ledger-v1:${operation.value}:${session.value}:$ordinal',
        ),
      )
      .toString();
  return LedgerId(
    '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
    '8${hex.substring(13, 16)}-a${hex.substring(17, 20)}-${hex.substring(20, 32)}',
  );
}
