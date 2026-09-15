import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/platform/audio/completion_chime.dart';
import 'package:minutrove/platform/notifications/completion_notifier.dart';
import 'package:minutrove/platform/notifications/notification_taps.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/support.dart' as f;
import '../support/session_fixtures.dart';

class FakeScheduler implements NotificationScheduler, CompletionDeliveryOwner {
  FakeScheduler(this.answer);
  NotificationPermission answer;
  final desiredHistory = <List<NotificationIntent>>[];
  var _owned = <CompletionId>{};

  @override
  Future<NotificationPermission> permission() async => answer;

  @override
  Future<NotificationPermission> requestPermission({
    required OperationId operationId,
  }) async => answer;

  @override
  Future<Result<NotificationPermission>> reconcile({
    required OperationId operationId,
    required List<NotificationIntent> intents,
  }) async {
    desiredHistory.add(intents);
    _owned = {
      for (final intent in intents)
        if (answer == NotificationPermission.granted &&
            intent.deadlineUtc != null)
          intent.completionId,
    };
    return Success(answer);
  }

  @override
  Future<Result<bool>> openSystemSettings({
    required OperationId operationId,
  }) async => const Success<bool>(true);

  @override
  bool ownsDelivery(CompletionId completionId) => _owned.contains(completionId);

  final _taps = StreamController<NotificationTap>.broadcast();
  @override
  Stream<NotificationTap> get taps => _taps.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const chimeChannel = MethodChannel(CompletionChime.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory dir;
  late SqliteStore store;
  late SqliteSessionRepository sessions;
  late SessionClock clock;
  late Item quest;
  var serial = 1000;
  OperationId op() => OperationId(f.uuid(serial++));

  Future<SessionMutation> start() async => f.success(
    await sessions.startSession(
      operationId: op(),
      itemId: quest.id,
      expectedItemRevision: quest.revision,
      conflictChoice: SessionConflictChoice.cancel,
    ),
  );

  setUp(() async {
    messenger.setMockMethodCallHandler(chimeChannel, null);
    dir = await Directory.systemTemp.createTemp('minutrove-notifier-');
    store = f.success(
      await SqliteStore.open(
        path: '${dir.path}/test.db',
        factory: databaseFactoryFfi,
        currencies: f.metadata,
        initialSettings: f.settings,
      ),
    );
    clock = SessionClock();
    final calendar = SessionCalendar();
    sessions = SqliteSessionRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
    quest = f.success(
      await SqliteItemRepository(
        store: store,
        clock: clock,
        calendar: calendar,
      ).saveItem(
        operationId: op(),
        item: configuredQuest(seconds: 1),
        expectedRevision: null,
      ),
    );
  });

  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
    messenger.setMockMethodCallHandler(chimeChannel, null);
  });

  test('start, pause, resume and end reconcile the desired OS state', () async {
    final scheduler = FakeScheduler(NotificationPermission.granted);
    final notifier = CompletionNotifier(
      store: store,
      scheduler: scheduler,
      chime: CompletionChime(),
      isForeground: () => true,
    );
    final started = await start();
    expect(await notifier.onMutation(started), isA<Success<bool>>());
    final runningIntent = scheduler.desiredHistory.last.single;
    expect(runningIntent.deadlineUtc, started.session.deadlineUtc);
    expect(runningIntent.completionChimeHandled, isFalse);

    final paused = f.success(
      await sessions.pauseSession(
        operationId: op(),
        sessionId: started.session.id,
        expectedRevision: started.session.revision,
      ),
    );
    await notifier.onMutation(paused);
    expect(scheduler.desiredHistory.last.single.deadlineUtc, isNull);

    final resumed = f.success(
      await sessions.resumeSession(
        operationId: op(),
        sessionId: started.session.id,
        expectedRevision: paused.session.revision,
      ),
    );
    await notifier.onMutation(resumed);
    expect(
      scheduler.desiredHistory.last.single.completionId,
      runningIntent.completionId,
      reason: 'rescheduling keeps the stable identifier',
    );
    expect(scheduler.desiredHistory.last.single.deadlineUtc, isNotNull);

    final ended = f.success(
      await sessions.endSession(
        operationId: op(),
        sessionId: started.session.id,
        expectedRevision: resumed.session.revision,
      ),
    );
    await notifier.onMutation(ended);
    expect(ended.session.status, SessionStatus.ended);
    expect(scheduler.desiredHistory.last.single.deadlineUtc, isNull);
    final intents = f.success(
      await store.read((records) => records.notificationIntents()),
    );
    expect(
      intents.where((intent) => intent.completionChimeHandled),
      isNotEmpty,
      reason: 'an early end durably consumes any pending sound intent',
    );
  });

  test(
    'foreground completion with OS-owned delivery never replays the chime',
    () async {
      final plays = <String>[];
      messenger.setMockMethodCallHandler(chimeChannel, (call) async {
        plays.add(
          (call.arguments as Map<Object?, Object?>)['completionId'] as String,
        );
        return 'submitted';
      });
      final scheduler = FakeScheduler(NotificationPermission.granted);
      final notifier = CompletionNotifier(
        store: store,
        scheduler: scheduler,
        chime: CompletionChime(),
        isForeground: () => true,
      );
      final started = await start();
      await notifier.onMutation(started);
      clock.advance(1000);
      final completed = f.success(
        await sessions.reconcileSession(
          operationId: op(),
          sessionId: started.session.id,
        ),
      );
      expect(completed.session.status, SessionStatus.completed);
      await notifier.onMutation(completed);
      // The scheduled deadline notification already owned the single sound.
      expect(plays, isEmpty);
      final intents = f.success(
        await store.read((records) => records.notificationIntents()),
      );
      expect(intents.single.completionChimeHandled, isTrue);
      // A repeated callback (foreground tick, resume or replay) stays silent.
      await notifier.onMutation(completed);
      expect(plays, isEmpty);
    },
  );

  test(
    'foreground completion without OS ownership falls back exactly once',
    () async {
      final plays = <String>[];
      String? handledAtFirstPlay;
      messenger.setMockMethodCallHandler(chimeChannel, (call) async {
        if (plays.isEmpty) {
          final intents = f.success(
            await store.read((records) => records.notificationIntents()),
          );
          handledAtFirstPlay = intents.single.completionChimeHandled
              ? 'persisted'
              : 'missing';
        }
        plays.add(
          (call.arguments as Map<Object?, Object?>)['completionId'] as String,
        );
        return 'submitted';
      });
      final scheduler = FakeScheduler(NotificationPermission.denied);
      final notifier = CompletionNotifier(
        store: store,
        scheduler: scheduler,
        chime: CompletionChime(),
        isForeground: () => true,
      );
      final started = await start();
      await notifier.onMutation(started);
      expect(
        scheduler.ownsDelivery(started.session.completionId),
        isFalse,
        reason: 'denied permission schedules nothing for the OS to deliver',
      );
      clock.advance(1000);
      final completed = f.success(
        await sessions.reconcileSession(
          operationId: op(),
          sessionId: started.session.id,
        ),
      );
      expect(completed.session.status, SessionStatus.completed);
      expect(completed.session.settled, completed.session.duration);
      // 120000000 millionths/hour for exactly one second: exact accrual lands
      // in the committed wallet while notification delivery is unavailable.
      expect(
        completed.economy.wallet.balances.coins.units,
        greaterThan(0),
        reason: 'settlement stays exact while notifications are unavailable',
      );
      await notifier.onMutation(completed);
      expect(plays, hasLength(1));
      expect(plays.single, completed.session.completionId.value);
      expect(
        handledAtFirstPlay,
        'persisted',
        reason: 'the sound intent is consumed before playback is acknowledged',
      );
      await notifier.onMutation(completed);
      expect(plays, hasLength(1), reason: 'no repeated completion chime');
    },
  );

  test(
    'startup after termination marks terminal intents handled without sound',
    () async {
      final plays = <String>[];
      messenger.setMockMethodCallHandler(chimeChannel, (call) async {
        plays.add(
          (call.arguments as Map<Object?, Object?>)['completionId'] as String,
        );
        return 'submitted';
      });
      // No notifier is attached: the process "dies" before consuming the sound.
      final started = await start();
      clock.advance(1000);
      final completed = f.success(
        await sessions.reconcileSession(
          operationId: op(),
          sessionId: started.session.id,
        ),
      );
      expect(completed.session.status, SessionStatus.completed);
      final scheduler = FakeScheduler(NotificationPermission.granted);
      final notifier = CompletionNotifier(
        store: store,
        scheduler: scheduler,
        chime: CompletionChime(),
        isForeground: () => true,
      );
      await notifier.startup();
      expect(
        plays,
        isEmpty,
        reason: 'a relaunch must not replay the completed chime',
      );
      final intents = f.success(
        await store.read((records) => records.notificationIntents()),
      );
      expect(intents.single.completionChimeHandled, isTrue);
      expect(
        scheduler.desiredHistory.single.single.deadlineUtc,
        isNull,
        reason: 'a completed session leaves nothing pending after a restart',
      );
    },
  );

  test(
    'suppressed sound leaves settlement intact with no second attempt',
    () async {
      final plays = <String>[];
      messenger.setMockMethodCallHandler(chimeChannel, (call) async {
        plays.add(
          (call.arguments as Map<Object?, Object?>)['completionId'] as String,
        );
        return 'suppressed';
      });
      final scheduler = FakeScheduler(NotificationPermission.denied);
      final notifier = CompletionNotifier(
        store: store,
        scheduler: scheduler,
        chime: CompletionChime(),
        isForeground: () => true,
      );
      final started = await start();
      clock.advance(1000);
      final completed = f.success(
        await sessions.reconcileSession(
          operationId: op(),
          sessionId: started.session.id,
        ),
      );
      expect(completed.session.status, SessionStatus.completed);
      expect(completed.session.settled, completed.session.duration);
      await notifier.onMutation(completed);
      await notifier.onMutation(completed);
      expect(
        plays,
        hasLength(1),
        reason: 'one fallback attempt even when the OS suppresses the cue',
      );
    },
  );
}
