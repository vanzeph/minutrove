import 'dart:async';

import 'package:flutter/services.dart';

import '../../data/sqlite_store.dart';
import '../../domain/domain.dart';
import '../audio/completion_chime.dart';
import 'notification_taps.dart';

/// Notification syncing is desired-state reconciliation, not an economic
/// command: concurrent triggers collapse into one native sync, while the
/// stable OS identifiers keep every serialized attempt idempotent.
final notificationSyncOperation = OperationId(
  '00000000-0000-4000-8000-00000000f001',
);

/// Reconciles persisted notification intents with the OS after every
/// committed session mutation and consumes the one-shot completion sound
/// exactly once per completion.
///
/// Sound ownership follows the design: the scheduled deadline notification
/// owns the single audible cue whenever the OS accepted it. The immediate
/// chime is only a foreground fallback for completions the OS never owned,
/// and it is never replayed after a restart, an early end, or a repeated
/// callback. Economic settlement is never affected by any decision here.
///
/// Own one instance per open store and keep it alive for the app lifetime.
final class CompletionNotifier {
  CompletionNotifier({
    required this.store,
    required this.scheduler,
    required this.chime,
    required this.isForeground,
  });

  final SqliteStore store;
  final NotificationScheduler scheduler;

  /// One-shot cue adapter; it suppresses itself under denied sound settings.
  final CompletionChime chime;
  final bool Function() isForeground;
  final _played = <CompletionId>{};

  /// Deduplicated notification taps for Home routing. Each completion routes
  /// at most once per process; schedulers without tap forwarding expose an
  /// empty stream.
  Stream<NotificationTap> get taps => scheduler is CompletionDeliveryOwner
      ? (scheduler as CompletionDeliveryOwner).taps
      : const Stream.empty();

  /// Startup recovery after the store opens. Never plays sound: terminal
  /// intents found on disk are marked handled so a relaunch cannot replay the
  /// chime, and live deadlines are rescheduled idempotently.
  Future<Result<bool>> startup() => _refresh(playCompletion: null);

  /// Call once per committed [SessionMutation], including command replays and
  /// lifecycle recovery results. Repeated terminal mutations are no-ops.
  Future<Result<bool>> onMutation(SessionMutation mutation) {
    final session = mutation.session;
    final terminal =
        session.status == SessionStatus.completed ||
        session.status == SessionStatus.ended;
    final intent = mutation.notificationIntent;
    CompletionId? play;
    if (terminal &&
        !intent.completionChimeHandled &&
        session.status == SessionStatus.completed &&
        isForeground() &&
        !_osOwns(intent.completionId)) {
      play = intent.completionId;
    }
    return _refresh(playCompletion: play);
  }

  /// Persists `completionChimeHandled` for every terminal intent before any
  /// sound is acknowledged, then syncs the desired OS state. A failed write
  /// is reported and suppresses playback.
  Future<Result<bool>> _refresh({CompletionId? playCompletion}) async {
    final read = await store.read((records) => records.notificationIntents());
    if (read is Failure<List<NotificationIntent>>) {
      return Failure<bool>(read.error);
    }
    final intents = (read as Success<List<NotificationIntent>>).value;
    final unhandled = [
      for (final intent in intents)
        if (intent.deadlineUtc == null && !intent.completionChimeHandled)
          intent,
    ];
    for (final intent in unhandled) {
      final write = await store.write(
        (tx) => tx.putNotificationIntent(
          NotificationIntent(
            sessionId: intent.sessionId,
            sessionRevision: intent.sessionRevision,
            completionId: intent.completionId,
            deadlineUtc: null,
            completionChimeHandled: true,
          ),
        ),
      );
      if (write is Failure<void>) return Failure<bool>(write.error);
    }
    if (playCompletion != null &&
        _played.add(playCompletion) &&
        // A replayed command result still carries its frozen pre-consumption
        // intent. Only the write that actually consumes the stored marker may
        // acknowledge playback; later replays find `handled` persisted.
        unhandled.any((intent) => intent.completionId == playCompletion)) {
      try {
        await chime.playOnce(playCompletion.value);
      } on PlatformException {
        // Submission failures are not economic failures. The persisted marker
        // is retained: retrying an ambiguous request could repeat the cue.
      }
    }
    final result = await scheduler.reconcile(
      operationId: notificationSyncOperation,
      intents: intents,
    );
    return switch (result) {
      Success<NotificationPermission>() => const Success<bool>(true),
      Failure<NotificationPermission>(:final error) => Failure<bool>(error),
    };
  }

  bool _osOwns(CompletionId completionId) =>
      scheduler is CompletionDeliveryOwner &&
      (scheduler as CompletionDeliveryOwner).ownsDelivery(completionId);
}
