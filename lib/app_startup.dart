import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import 'app.dart';
import 'data/data.dart';
import 'data/pinned_currencies.dart';
import 'domain/domain.dart';
import 'features/home/home.dart';
import 'features/items/items.dart';
import 'features/sessions/sessions.dart';
import 'features/settings/settings.dart';
import 'features/shop/shop.dart';
import 'features/stats/stats.dart';
import 'platform/audio/completion_chime.dart';
import 'platform/clock/device_zone.dart';
import 'platform/clock/native_clock.dart';
import 'platform/files/backup_files.dart';
import 'platform/notifications/android_notifications.dart';
import 'platform/notifications/completion_notifier.dart';
import 'platform/notifications/ios_notification_scheduler.dart';
import 'platform/notifications/notification_taps.dart';
import 'platform/sessions/recovery_diagnostics.dart';
import 'platform/sessions/session_lifecycle.dart';
import 'platform/sessions/session_recovery.dart';
import 'ui/core/core.dart';

/// Composition adapter for Android: the platform scheduler reports the
/// completions whose deadline cue the OS already delivered and still owns, so
/// the foreground fallback chime can be suppressed after OS delivery. Launch
/// and re-entry taps arrive through `consumeLaunchCompletion`, which the
/// composition probes at startup and on every resume; each tap is forwarded
/// exactly once. The bridge outlives composition rebuilds after a restore.
final class AndroidCompletionBridge
    implements NotificationScheduler, CompletionDeliveryOwner {
  AndroidCompletionBridge(this.scheduler);

  final AndroidNotificationScheduler scheduler;

  /// Completions whose delivered notification the OS still owns, from the last
  /// successful native sync. Clearing on a failed sync mirrors iOS: ownership
  /// is never partially assumed.
  final _delivered = <CompletionId>{};
  final _taps = StreamController<NotificationTap>.broadcast();

  @override
  Stream<NotificationTap> get taps => _taps.stream;

  @override
  bool ownsDelivery(CompletionId completionId) =>
      _delivered.contains(completionId);

  @override
  Future<NotificationPermission> permission() => scheduler.permission();

  @override
  Future<NotificationPermission> requestPermission({
    required OperationId operationId,
  }) => scheduler.requestPermission(operationId: operationId);

  @override
  Future<Result<NotificationPermission>> reconcile({
    required OperationId operationId,
    required List<NotificationIntent> intents,
  }) async {
    final detailed = await scheduler.reconcileDetailed(
      operationId: operationId,
      intents: intents,
    );
    switch (detailed) {
      case Success<NotificationReconciliation>(:final value):
        _delivered
          ..clear()
          ..addAll(value.delivered);
        return Success<NotificationPermission>(value.permission);
      case Failure<NotificationReconciliation>(:final error):
        _delivered.clear();
        return Failure<NotificationPermission>(error);
    }
  }

  @override
  Future<Result<bool>> openSystemSettings({required OperationId operationId}) =>
      scheduler.openSystemSettings(operationId: operationId);

  /// Forwards one launch or re-entry tap, if the native side captured any.
  Future<void> probeLaunchCompletion() async {
    final completion = await scheduler.consumeLaunchCompletion();
    if (completion != null && !_taps.isClosed) {
      _taps.add(NotificationTap(completionId: completion));
    }
  }

  Future<void> dispose() async => _taps.close();
}

/// Serializes one notification sync after every committed session mutation,
/// whatever produced it: a UI command, the lifecycle timer, or startup and
/// resume recovery. The sync itself is best-effort desired-state convergence;
/// a failed sync never changes the committed economic result handed to the UI.
final class NotifyingSessions implements SessionRepository {
  NotifyingSessions(this.inner, this.notifier);
  final SessionRepository inner;
  final CompletionNotifier notifier;
  Future<void> _tail = Future.value();

  @override
  Future<Result<Session?>> getSession(SessionId id) => inner.getSession(id);

  @override
  Stream<Session?> watchActiveSession() => inner.watchActiveSession();

  @override
  Future<Result<SessionMutation>> startSession({
    required OperationId operationId,
    required ItemId itemId,
    required Revision expectedItemRevision,
    required SessionConflictChoice conflictChoice,
  }) => _syncing(
    () => inner.startSession(
      operationId: operationId,
      itemId: itemId,
      expectedItemRevision: expectedItemRevision,
      conflictChoice: conflictChoice,
    ),
  );

  @override
  Future<Result<SessionMutation>> pauseSession({
    required OperationId operationId,
    required SessionId sessionId,
    required Revision expectedRevision,
  }) => _syncing(
    () => inner.pauseSession(
      operationId: operationId,
      sessionId: sessionId,
      expectedRevision: expectedRevision,
    ),
  );

  @override
  Future<Result<SessionMutation>> resumeSession({
    required OperationId operationId,
    required SessionId sessionId,
    required Revision expectedRevision,
  }) => _syncing(
    () => inner.resumeSession(
      operationId: operationId,
      sessionId: sessionId,
      expectedRevision: expectedRevision,
    ),
  );

  @override
  Future<Result<SessionMutation>> endSession({
    required OperationId operationId,
    required SessionId sessionId,
    required Revision expectedRevision,
  }) => _syncing(
    () => inner.endSession(
      operationId: operationId,
      sessionId: sessionId,
      expectedRevision: expectedRevision,
    ),
  );

  @override
  Future<Result<SessionMutation>> reconcileSession({
    required OperationId operationId,
    required SessionId sessionId,
  }) => _syncing(
    () =>
        inner.reconcileSession(operationId: operationId, sessionId: sessionId),
  );

  Future<Result<SessionMutation>> _syncing(
    Future<Result<SessionMutation>> Function() command,
  ) async {
    final result = await command();
    if (result is Success<SessionMutation>) {
      final mutation = result.value;
      _tail = _tail
          .then((_) => notifier.onMutation(mutation))
          .then((_) {}, onError: (_) {});
    }
    return result;
  }

  Future<void> drain() => _tail;
}

/// The live app object graph over one open store. Everything the screens
/// share — repositories, clocks, notification reconciliation, the session
/// lifecycle — is created together and replaced together after a backup
/// restore swaps the database file.
final class AppComposition with WidgetsBindingObserver {
  AppComposition._({
    required this.restorer,
    required this.calendar,
    required this.clock,
    required this.scheduler,
    required this.bridge,
    required this.chime,
    required this.diagnostics,
  });

  /// Opens the store (creating it only when genuinely absent) and builds the
  /// whole object graph over it.
  static Future<Result<AppComposition>> open({
    required String databasePath,
    required sqflite.DatabaseFactory factory,
    required IanaReportingCalendar calendar,
    required Clock clock,
    required NotificationScheduler scheduler,
    required CompletionChime chime,
    required File diagnosticsFile,
    Future<ReportingZone> Function()? readDeviceZone,
  }) async {
    final bridge = scheduler is AndroidNotificationScheduler
        ? AndroidCompletionBridge(scheduler)
        : null;
    final opened = await SqliteBackupRestorer.open(
      path: databasePath,
      factory: factory,
      currencies: const PinnedCurrencies(),
      initialSettings: AppSettings(
        revision: Revision(1),
        reportingZone:
            await (readDeviceZone ??
                () => deviceReportingZone(calendar: calendar))(),
      ),
      clock: clock,
      calendar: calendar,
      scheduler: bridge ?? scheduler,
    );
    return switch (opened) {
      Success<SqliteBackupRestorer>(:final value) => Success(
        AppComposition._(
          restorer: value,
          calendar: calendar,
          clock: clock,
          scheduler: bridge ?? scheduler,
          bridge: bridge,
          chime: chime,
          diagnostics: LocalRecoveryDiagnostics(diagnosticsFile),
        ),
      ),
      Failure<SqliteBackupRestorer>(:final error) => Failure(error),
    };
  }

  final SqliteBackupRestorer restorer;
  final IanaReportingCalendar calendar;
  final Clock clock;
  final NotificationScheduler scheduler;
  final AndroidCompletionBridge? bridge;
  final CompletionChime chime;
  final LocalRecoveryDiagnostics diagnostics;

  late final SqliteStore store = restorer.store;
  late final CompletionNotifier notifier = CompletionNotifier(
    store: store,
    scheduler: scheduler,
    chime: chime,
    isForeground: () {
      final state = WidgetsBinding.instance.lifecycleState;
      return state == null ||
          state == AppLifecycleState.resumed ||
          state == AppLifecycleState.inactive;
    },
  );
  late final NotifyingSessions sessions = NotifyingSessions(
    SqliteSessionRepository(store: store, clock: clock, calendar: calendar),
    notifier,
  );
  late final SessionLifecycle lifecycle = SessionLifecycle(
    recovery: SessionRecovery(
      store: store,
      sessions: sessions,
      recordDiagnostic: diagnostics.record,
    ),
    clock: clock,
    operationId: _newOperationId,
  );
  late final SqliteItemRepository items = SqliteItemRepository(
    store: store,
    clock: clock,
    calendar: calendar,
  );
  late final SqliteEconomyRepository economy = SqliteEconomyRepository(
    store: store,
    clock: clock,
    calendar: calendar,
  );
  late final SqliteSettingsRepository settings = SqliteSettingsRepository(
    store: store,
    clock: clock,
    calendar: calendar,
  );
  late final ItemEditing editing = ItemEditing(
    repository: items,
    currencies: const PinnedCurrencies(),
    readFacts: sqliteItemEditFacts(store),
  );
  late final StatsSource statsSource = SqliteStatsSource(
    store: store,
    calendar: calendar,
    // The reporting date follows the same injected clock as every command,
    // never a second uncoordinated wall-clock source. The mapping stays
    // synchronous for synchronous clocks: this stats reader runs inside the
    // store's serialized watch-refresh chain on every commit, and one extra
    // microtask hop there deadlocks the runAsync-driven widget suites on a
    // fake zone.
    utcNow: () {
      final reading = clock.now();
      return reading is Future<ClockReading>
          ? reading.then((value) => value.utc)
          : reading.utc;
    },
  );
  late final BackupRepository backup = SqliteBackupRepository(
    restorer: restorer,
    clock: clock,
  );
  late final SessionRoute sessionRoute = SessionRoute(
    sessions: sessions,
    clock: clock,
    watchSession: (id) => watchSqliteSession(store, id),
    reconcile: () => lifecycle.reconcile(),
    operationId: _newOperationId,
  );
  late final AwardExpenseRoute expenseRoute = AwardExpenseRoute(
    economy: economy,
    watchHome: () => watchSqliteHome(store),
    readHome: () => readSqliteHome(store),
    operationId: _newOperationId,
  );

  /// Notification taps from either platform; each routes Home once.
  final _routeHome = StreamController<void>.broadcast();
  Stream<void> get routeHome => _routeHome.stream;
  StreamSubscription<NotificationTap>? _taps;
  bool _disposed = false;

  /// Startup: recover notifications before sessions so a relaunch cannot
  /// replay a completed cue, then reconcile the persisted session slot and
  /// begin lifecycle checkpointing. Await before exposing session commands.
  Future<void> start() async {
    if (_disposed) return;
    // Registered before the lifecycle observer: on resume the delivered-set
    // probe and tap routing run ahead of session settlement.
    WidgetsBinding.instance.addObserver(this);
    await notifier.startup();
    if (_disposed) return;
    final bridge = this.bridge;
    if (bridge != null) await bridge.probeLaunchCompletion();
    await lifecycle.start();
    if (_disposed) return;
    _taps = notifier.taps.listen((_) {
      if (!_routeHome.isClosed) _routeHome.add(null);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed || state != AppLifecycleState.resumed) return;
    unawaited(_resumed());
  }

  Future<void> _resumed() async {
    final bridge = this.bridge;
    // A warm re-entry tap is captured natively on new-intent; route it Home.
    if (bridge != null) await bridge.probeLaunchCompletion();
    if (_disposed) return;
    // Refresh OS delivery ownership before lifecycle settlement decides the
    // foreground fallback chime, so an OS-delivered cue is not replayed.
    final read = await store.read((records) => records.notificationIntents());
    if (_disposed) return;
    if (read case Success<List<NotificationIntent>>(:final value)) {
      await scheduler.reconcile(
        operationId: notificationSyncOperation,
        intents: value,
      );
    }
  }

  /// Rebuilds every adapter over the reopened database after a validated
  /// restore replaced the live file. The old lifecycle is disposed first so no
  /// timer or observer survives into the new graph; the platform bridge is
  /// shared because its native state outlives the swap.
  Future<AppComposition> rebuild() async {
    final replacement = AppComposition._(
      restorer: restorer,
      calendar: calendar,
      clock: clock,
      scheduler: scheduler,
      bridge: bridge,
      chime: chime,
      diagnostics: diagnostics,
    );
    await dispose();
    await replacement.start();
    return replacement;
  }

  /// Tears down observers, timers and in-flight syncs. Keeps the bridge and
  /// the store open: a rebuild continues over the same platform state.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    await _taps?.cancel();
    // The lifecycle drains its in-flight recovery before the store goes away.
    await lifecycle.dispose();
    await sessions.drain();
    await _routeHome.close();
  }

  /// Full teardown including the store and platform bridge.
  Future<void> close() async {
    await dispose();
    await restorer.close();
    await bridge?.dispose();
  }
}

OperationId _newOperationId() => OperationId(randomUuid());

NotificationScheduler _platformScheduler() => switch (defaultTargetPlatform) {
  TargetPlatform.android => AndroidNotificationScheduler(),
  _ => IosNotificationScheduler(),
};

/// Application startup: open the persisted store with real adapters, recover
/// notifications and the session slot, gate first-run onboarding, and wire
/// every route over the shared composition. A failed open shows an actionable
/// retry; a restore rebuilds the graph over the reopened database.
class MinutroveStartup extends StatefulWidget {
  const MinutroveStartup({super.key, this.open});

  /// Replaces the production opener in tests. The flag reports a database
  /// about to be created, which gates first-run onboarding.
  final Future<Result<(AppComposition, bool firstRun)>> Function()? open;
  @override
  State<MinutroveStartup> createState() => _MinutroveStartupState();
}

class _MinutroveStartupState extends State<MinutroveStartup> {
  _Phase _phase = _Phase.loading;
  Object? _error;
  AppComposition? _composition;
  bool _onboarding = false;
  bool _restoring = false;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    setState(() => _phase = _Phase.loading);
    final result = await (widget.open ?? _openNative)();
    switch (result) {
      case Success(:final value):
        final (composition, firstRun) = value;
        await composition.start();
        if (!mounted) {
          await composition.close();
          return;
        }
        setState(() {
          _composition = composition;
          _onboarding = firstRun;
          _phase = _Phase.ready;
        });
      case Failure(:final error):
        if (mounted) {
          setState(() {
            _error = error;
            _phase = _Phase.failed;
          });
        }
        return;
    }
  }

  /// Production opener: first run means no database file exists yet, so the
  /// store is about to be created and onboarding runs once.
  Future<Result<(AppComposition, bool firstRun)>> _openNative() async {
    final directory = await sqflite.getDatabasesPath();
    final databasePath = '$directory/minutrove.db';
    final firstRun = !File(databasePath).existsSync();
    final result = await AppComposition.open(
      databasePath: databasePath,
      factory: sqflite.databaseFactory,
      calendar: IanaReportingCalendar(),
      clock: const NativeClock(),
      scheduler: _platformScheduler(),
      chime: CompletionChime(),
      diagnosticsFile: File('$directory/minutrove.recovery.log'),
    );
    return switch (result) {
      Success<AppComposition>(:final value) => Success((value, firstRun)),
      Failure<AppComposition>(:final error) => Failure(error),
    };
  }

  @override
  void dispose() {
    final composition = _composition;
    if (composition != null) {
      // Best effort at shutdown; committed SQLite state is already durable.
      unawaited(composition.close());
    }
    super.dispose();
  }

  Future<void> _onRestored() async {
    final composition = _composition;
    if (composition == null || _restoring) return;
    setState(() => _restoring = true);
    try {
      final rebuilt = await composition.rebuild();
      if (!mounted) {
        await rebuilt.close();
        return;
      }
      setState(() {
        _composition = rebuilt;
        _epoch++;
        // The restored database is existing data, never a first run.
        _onboarding = false;
      });
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MinutroveApp(
      home: switch (_phase) {
        _Phase.loading => const _StartupProgress(),
        _Phase.failed => _StartupFailed(error: _error, retry: _open),
        _Phase.ready => _buildApp(),
      },
    );
  }

  Widget _buildApp() {
    final composition = _composition!;
    if (_onboarding) {
      return OnboardingFlow(
        settings: composition.settings,
        notifications: composition.scheduler,
        onFinished: () {
          if (mounted) setState(() => _onboarding = false);
        },
      );
    }
    final store = composition.store;
    return KeyedSubtree(
      key: ValueKey(_epoch),
      child: HomeShell(
        watchHome: () => watchSqliteHome(store),
        editing: composition.editing,
        sessions: composition.sessions,
        clock: composition.clock,
        routeHome: composition.routeHome,
        routes: HomeRoutes(
          shop: (_) => ShopScreen(
            watchShop: () => watchSqliteHome(store),
            economy: composition.economy,
            editing: composition.editing,
          ),
          stats: (_) => StatsScreen(source: composition.statsSource),
          openSession: (context, id, returnHome) =>
              composition.sessionRoute.open(context, id, returnHome),
          openExpense: (context, item, balance, choice) =>
              composition.expenseRoute.open(context, item, balance, choice),
          openSettings: (context) async {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(
                  settings: composition.settings,
                  notifications: composition.scheduler,
                  backup: composition.backup,
                  picker: const MethodChannelBackupFiles(),
                  sharer: const MethodChannelBackupFiles(),
                  onRestored: _onRestored,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

enum _Phase { loading, failed, ready }

class _StartupProgress extends StatelessWidget {
  const _StartupProgress();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: TroveActivityIndicator()));
}

class _StartupFailed extends StatelessWidget {
  const _StartupFailed({required this.error, required this.retry});

  final Object? error;
  final Future<void> Function() retry;

  @override
  Widget build(BuildContext context) {
    final failure = error;
    final retryable = failure is StorageUnavailable && failure.retryable;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      'Minutrove could not open your data',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Your saved items, balances and history are still on this '
                    'device. Nothing was changed.',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Free up space or close other apps, then try again. A '
                    'backup file remains usable even if opening keeps failing.',
                  ),
                  const SizedBox(height: 20),
                  TroveButton(
                    label: 'Try again',
                    onPressed: retryable ? () => retry() : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
