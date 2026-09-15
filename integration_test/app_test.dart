import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app.dart';
import 'package:minutrove/features/sessions/sessions.dart';
import 'package:minutrove/ui/core/core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/data/native_store.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/main.dart' as app;
import 'package:flutter/services.dart';
import 'package:minutrove/platform/audio/completion_chime.dart';
import 'package:minutrove/platform/clock/native_clock.dart';
import 'package:minutrove/platform/notifications/completion_notifier.dart';
import 'package:minutrove/platform/notifications/ios_notification_scheduler.dart';
import 'package:minutrove/platform/sessions/recovery_diagnostics.dart';
import 'package:minutrove/platform/sessions/session_recovery.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;

import '../test/data/support.dart' as f;
import '../test/support/session_fixtures.dart';
import '../test/support/backup_portability.dart' as p;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('MINUTROVE_NATIVE_XCTEST')) {
    // XCTest enables platform semantics after the app launches. Wait before
    // testWidgets records its handle baseline, so that platform-owned handle
    // is not mistaken for a handle leaked by the app during the test.
    setUpAll(() async {
      await Future<void>(() async {
        while (!binding.platformDispatcher.semanticsEnabled) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }).timeout(const Duration(seconds: 30));
    });
  }

  testWidgets('native launch and navigation smoke', (tester) async {
    app.main();
    await tester.pumpAndSettle();
    // A fresh install opens the real onboarding; skipping reaches the live
    // Home shell over the on-device SQLite store.
    expect(find.text('Turn your time into treasure'), findsOneWidget);
    await tester.tap(find.text('Skip setup'));
    await tester.pumpAndSettle();
    const destinations = {
      'Shop': 'Reward Shop',
      'Stats': 'Your progress',
      'Home': 'Make time for what matters.',
    };
    for (final destination in destinations.entries) {
      await tester.tap(find.text(destination.key));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(destination.value), findsOneWidget);
    }
  });

  testWidgets(
    'native clock and SQLite reopen recover a deadline exactly once',
    (tester) async {
      const clock = NativeClock();
      final before = await clock.now();
      final dir = await Directory.systemTemp.createTemp(
        'minutrove-native-recovery-',
      );
      SqliteStore? store;
      Future<SqliteStore> open() async => f.success(
        await openNativeStore(
          path: '${dir.path}/recovery.db',
          currencies: f.metadata,
          initialSettings: f.settings,
        ),
      );
      final calendar = SessionCalendar();
      try {
        store = await open();
        final item = f.success(
          await SqliteItemRepository(
            store: store,
            clock: clock,
            calendar: calendar,
          ).saveItem(
            operationId: OperationId(f.uuid(100)),
            item: configuredQuest(seconds: 1),
            expectedRevision: null,
          ),
        );
        final started = f.success(
          await SqliteSessionRepository(
            store: store,
            clock: clock,
            calendar: calendar,
          ).startSession(
            operationId: OperationId(f.uuid(101)),
            itemId: item.id,
            expectedItemRevision: item.revision,
            conflictChoice: SessionConflictChoice.cancel,
          ),
        );
        await store.close();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        store = await open();
        final sessions = SqliteSessionRepository(
          store: store,
          clock: clock,
          calendar: calendar,
        );
        final recovery = SessionRecovery(
          store: store,
          sessions: sessions,
          recordDiagnostic: LocalRecoveryDiagnostics(
            File('${dir.path}/recovery.log'),
          ).record,
        );
        final finished = f.success(
          await recovery.reconcile(operationId: OperationId(f.uuid(102))),
        )!;
        expect(finished.session.status, SessionStatus.completed);
        expect(finished.session.settled.value, 1000);
        expect(finished.session.completionId, started.session.completionId);
        expect(finished.economy.wallet.balances.coins.units, 33333);
        expect(
          f.success(
            await recovery.reconcile(operationId: OperationId(f.uuid(103))),
          ),
          isNull,
        );
        final after = await const NativeClock().now();
        expect(after.bootId, before.bootId);
        expect(
          after.monotonic.value,
          greaterThanOrEqualTo(before.monotonic.value + 1100),
        );
        expect(
          f.success(await store.read((r) => r.projectionMismatches())),
          isEmpty,
        );
      } finally {
        await store?.close();
        await dir.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'native session view pauses, resumes and ends with durable earnings',
    (tester) async {
      const clock = NativeClock();
      final dir = await Directory.systemTemp.createTemp(
        'minutrove-native-session-ui-',
      );
      final store = f.success(
        await openNativeStore(
          path: '${dir.path}/session.db',
          currencies: f.metadata,
          initialSettings: f.settings,
        ),
      );
      final calendar = SessionCalendar();
      final sessions = SqliteSessionRepository(
        store: store,
        clock: clock,
        calendar: calendar,
      );
      var serial = 500;
      OperationId operation() => OperationId(f.uuid(serial++));
      var returned = 0;
      try {
        final item = f.success(
          await SqliteItemRepository(
            store: store,
            clock: clock,
            calendar: calendar,
          ).saveItem(
            operationId: operation(),
            item: configuredQuest(seconds: 600),
            expectedRevision: null,
          ),
        );
        final started = f.success(
          await sessions.startSession(
            operationId: operation(),
            itemId: item.id,
            expectedItemRevision: item.revision,
            conflictChoice: SessionConflictChoice.cancel,
          ),
        );
        final recovery = SessionRecovery(
          store: store,
          sessions: sessions,
          recordDiagnostic: (_) async {},
        );
        final route = SessionRoute(
          sessions: sessions,
          clock: clock,
          watchSession: (id) => watchSqliteSession(store, id),
          reconcile: () => recovery.reconcile(operationId: operation()),
          operationId: operation,
        );
        await tester.pumpWidget(
          MinutroveApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TroveButton(
                    label: 'Open current session',
                    onPressed: () => route.open(
                      context,
                      started.session.id,
                      () => returned++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open current session'));
        Future<void> ready(String label) async {
          for (var attempt = 0; attempt < 100; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            await tester.pump();
            final matches = tester.widgetList<TroveButton>(
              find.widgetWithText(TroveButton, label),
            );
            if (matches.any((button) => button.onPressed != null)) return;
          }
          fail('Session action did not become ready: $label');
        }

        await ready('Pause session');
        await tester.ensureVisible(find.text('Pause session'));
        await tester.tap(find.text('Pause session'));
        await ready('Resume session');
        final paused = f.success(
          await sessions.getSession(started.session.id),
        )!;
        expect(paused.status, SessionStatus.paused);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await recovery.reconcile(operationId: operation());
        expect(
          f.success(await sessions.getSession(paused.id))!.settled.value,
          paused.settled.value,
        );
        await tester.ensureVisible(find.text('Resume session'));
        await tester.tap(find.text('Resume session'));
        await ready('Pause session');
        await tester.ensureVisible(find.text('End & keep earnings'));
        await tester.tap(find.text('End & keep earnings'));
        for (var attempt = 0; attempt < 100 && returned == 0; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(returned, 1);
        expect(find.text('Open current session'), findsOneWidget);
        final ended = f.success(await sessions.getSession(paused.id))!;
        expect(ended.status, SessionStatus.ended);
        expect(ended.settled.value, greaterThanOrEqualTo(paused.settled.value));
        expect(f.success(await store.read((r) => r.activeSession())), isNull);
        expect(
          f.success(await store.read((r) => r.projectionMismatches())),
          isEmpty,
        );
        final view = await watchSqliteSession(store, ended.id).first;
        expect(
          view!.earned.coins.units,
          f.success(await store.read((r) => r.wallet())).balances.coins.units,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await store.close();
        await dir.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'iOS notifications sync stably and a suppressed chime keeps settlement exact',
    (tester) async {
      if (!Platform.isIOS) {
        // The channel contract under test is implemented by the iOS runner;
        // other platforms skip rather than fail on a missing handler.
        markTestSkipped('iOS-only notification channel');
        return;
      }
      final scheduler = IosNotificationScheduler();
      final permission = await scheduler.permission();
      expect(
        permission,
        anyOf(
          equals(NotificationPermission.notDetermined),
          equals(NotificationPermission.granted),
          equals(NotificationPermission.denied),
          equals(NotificationPermission.restricted),
        ),
        reason: 'The native permission status must map to the domain enum',
      );

      // Desired-state contract against the real UserNotifications center.
      // Recorded simulator limit: without authorization the center silently
      // holds nothing, so a pending answer is either exactly the one stable
      // identifier (authorized host) or empty; anything else is a defect.
      // Cancellation must always reconcile to empty. Stable identifier
      // replacement is the primitive behind pause/resume/end and crash
      // reconciliation; the fully observable form runs in the native suite.
      const channel = MethodChannel(IosNotificationScheduler.channelName);
      const completionId = 'aaaaaaaa-1a1a-4a1a-8a1a-111111111111';
      final now = DateTime.now().toUtc();
      Future<List<Object?>?> sync(int offsetSeconds) =>
          channel.invokeListMethod<Object?>('syncRequests', {
            'operationId': 'synthetic-sync',
            'desired': [
              {
                'completionId': completionId,
                'deadlineMilliseconds': now
                    .add(Duration(seconds: offsetSeconds))
                    .millisecondsSinceEpoch,
              },
            ],
          });
      final scheduled = await sync(600);
      expect(scheduled, anyOf(isEmpty, ['minutrove.completion.$completionId']));
      final rescheduled = await sync(1200);
      expect(
        rescheduled,
        anyOf(isEmpty, ['minutrove.completion.$completionId']),
        reason: 'Rescheduling replaces the same stable identifier',
      );
      final cancelled = await channel.invokeListMethod<Object?>(
        'syncRequests',
        {'operationId': 'synthetic-sync', 'desired': <Object>[]},
      );
      expect(cancelled, isEmpty, reason: 'A pause or end cancels the request');

      // Full lifecycle with the real store, clock and chime. Without
      // authorization the OS owns nothing, so the foreground fallback is
      // submitted and suppressed by system sound policy; settlement and the
      // durable handled marker must both stay exact, with no repeat.
      final dir = await Directory.systemTemp.createTemp(
        'minutrove-native-notifications-',
      );
      SqliteStore? store;
      try {
        const clock = NativeClock();
        final db = f.success(
          await openNativeStore(
            path: '${dir.path}/notifications.db',
            currencies: f.metadata,
            initialSettings: f.settings,
          ),
        );
        store = db;
        final calendar = SessionCalendar();
        final item = f.success(
          await SqliteItemRepository(
            store: db,
            clock: clock,
            calendar: calendar,
          ).saveItem(
            operationId: OperationId(f.uuid(200)),
            item: configuredQuest(seconds: 1),
            expectedRevision: null,
          ),
        );
        final sessions = SqliteSessionRepository(
          store: db,
          clock: clock,
          calendar: calendar,
        );
        final notifier = CompletionNotifier(
          store: db,
          scheduler: scheduler,
          chime: CompletionChime(),
          isForeground: () => true,
        );
        final started = f.success(
          await sessions.startSession(
            operationId: OperationId(f.uuid(201)),
            itemId: item.id,
            expectedItemRevision: item.revision,
            conflictChoice: SessionConflictChoice.cancel,
          ),
        );
        await notifier.onMutation(started);
        expect(
          scheduler.ownsDelivery(started.session.completionId),
          isFalse,
          reason: 'An unauthorized app leaves nothing pending',
        );
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        final completed = f.success(
          await sessions.reconcileSession(
            operationId: OperationId(f.uuid(202)),
            sessionId: started.session.id,
          ),
        );
        expect(completed.session.status, SessionStatus.completed);
        expect(completed.session.settled.value, 1000);
        expect(completed.economy.wallet.balances.coins.units, 33333);
        expect(await notifier.onMutation(completed), isA<Success<bool>>());
        final intents = f.success(
          await db.read((records) => records.notificationIntents()),
        );
        expect(
          intents.single.completionChimeHandled,
          isTrue,
          reason: 'The suppressed cue is still consumed exactly once',
        );
        expect(await notifier.onMutation(completed), isA<Success<bool>>());
        expect(
          f.success(await db.read((r) => r.projectionMismatches())),
          isEmpty,
        );
      } finally {
        await store?.close();
        await dir.delete(recursive: true);
      }
    },
    skip: !Platform.isIOS,
  );

  // Cross-platform backup portability: the same deterministic history runs
  // through this platform's real SQLite, and its export must equal the
  // committed reference bytes produced by every other platform. Because the
  // bytes are pinned, restoring them on a fresh store here is exactly what
  // restoring a file transferred from the other platform does.
  testWidgets(
    'this platform exports the cross-platform reference backup bytes',
    (tester) async {
      final dir = await Directory.systemTemp.createTemp(
        'minutrove-portability-export-',
      );
      final world = await p.buildPortabilityHistory(
        path: '${dir.path}/source.db',
        factory: databaseFactory,
      );
      try {
        final file = await world.export();
        expect(
          sha256.convert(file.bytes).toString(),
          p.portabilityReferenceSha256,
          reason: 'Every platform exports the same transferable bytes',
        );
        final coverage = await p.portabilityCoverage(file);
        expect(coverage['years'], [2023, 2024, 2025, 2026]);
        expect(coverage['budgetPrecisions'], [0, 2, 3]);
        expect(coverage['archived'], [p.questWork.value, p.awardCharm.value]);
        expect(coverage['achievements'], 5);
        expect(
          (coverage['remaindersNonZero'] as List),
          isNotEmpty,
          reason: 'Remainder carry survives this platform exactly',
        );
      } finally {
        await world.close();
        await dir.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'a transferred backup restores exact domain state and Stats here',
    (tester) async {
      final dir = await Directory.systemTemp.createTemp(
        'minutrove-portability-restore-',
      );
      final source = await p.buildPortabilityHistory(
        path: '${dir.path}/source.db',
        factory: databaseFactory,
      );
      SqliteBackupRestorer? target;
      try {
        final transferred = await source.export();
        final opened = await SqliteBackupRestorer.open(
          path: '${dir.path}/target.db',
          factory: databaseFactory,
          currencies: p.portabilityCurrencies,
          initialSettings: p.portabilitySettings,
          clock: p.PortabilityClock(),
          calendar: p.portabilityCalendar,
        );
        final restorer = f.success(opened);
        target = restorer;
        final beforeStats = await p.portabilityStatsBattery(source.store);
        final beforeState = await p.portabilityDomainState(source.store);

        final preview = f.success(await restorer.inspectBackup(transferred));
        expect(preview.sha256, p.portabilityReferenceSha256);
        expect(preview.createdUtc, p.portabilityCreatedUtc);
        expect(preview.version.value, 1);
        final liveSettings = f.success(
          await restorer.store.read((r) => r.settings()),
        );
        final receipt = f.success(
          await restorer.restoreBackup(
            operationId: OperationId(f.uuid(800)),
            file: transferred,
            confirmation: RestoreConfirmation(
              preview: preview,
              expectedSettingsRevision: liveSettings.revision,
            ),
          ),
        );
        expect(receipt.sourceSha256, p.portabilityReferenceSha256);

        expect(await p.portabilityDomainState(restorer.store), beforeState);
        expect(await p.portabilityStatsBattery(restorer.store), beforeStats);
        expect(
          f.success(await restorer.store.read((r) => r.activeSession())),
          isNull,
        );
        expect(
          f.success(await restorer.store.read((r) => r.projectionMismatches())),
          isEmpty,
        );
        // The replaced database still serves ordinary commands.
        final items = SqliteItemRepository(
          store: restorer.store,
          clock: p.PortabilityClock(),
          calendar: p.portabilityCalendar,
        );
        f.success(
          await items.saveGroup(
            operationId: OperationId(f.uuid(801)),
            group: Group(
              id: GroupId(f.uuid(802)),
              revision: Revision(1),
              name: 'After on-device restore',
              order: 9,
            ),
            expectedRevision: null,
          ),
        );
      } finally {
        await source.close();
        await target?.close();
        await dir.delete(recursive: true);
      }
    },
  );

  for (final (name, mutation) in [
    ('a flipped payload byte', 'corrupt'),
    ('a truncated tail', 'truncate'),
    ('a version from the future', 'future-version'),
    ('foreign pinned currency metadata', 'foreign-currencies'),
  ]) {
    testWidgets('$name leaves this device\'s original backup target usable', (
      tester,
    ) async {
      final dir = await Directory.systemTemp.createTemp(
        'minutrove-portability-failure-',
      );
      SqliteBackupRestorer? live;
      try {
        final opened = await SqliteBackupRestorer.open(
          path: '${dir.path}/live.db',
          factory: databaseFactory,
          currencies: p.portabilityCurrencies,
          initialSettings: p.portabilitySettings,
          clock: p.PortabilityClock(),
          calendar: p.portabilityCalendar,
        );
        final restorer = f.success(opened);
        live = restorer;
        final items = SqliteItemRepository(
          store: restorer.store,
          clock: p.PortabilityClock(),
          calendar: p.portabilityCalendar,
        );
        f.success(
          await items.saveItem(
            operationId: OperationId(f.uuid(810)),
            item: Item(
              id: p.questStudy,
              revision: Revision(1),
              name: 'Live-only quest',
              iconKey: 'gamepad',
              colorArgb: 0xff883366,
              groupId: null,
              order: 0,
              archived: false,
              configuration: QuestConfiguration(
                duration: Milliseconds.seconds(60),
                ratesPerHour: CurrencyAmounts(
                  coins: MicroAmount(1000000),
                  gems: MicroAmount(0),
                ),
              ),
            ),
            expectedRevision: null,
          ),
        );
        final world = await p.buildPortabilityHistory(
          path: '${dir.path}/source.db',
          factory: databaseFactory,
        );
        final file = p.mutatedBackup((await world.export()).bytes, mutation);
        await world.close();

        expect(
          await restorer.inspectBackup(file),
          isA<Failure<BackupPreview>>(),
        );
        expect(
          await restorer.restoreBackup(
            operationId: OperationId(f.uuid(811)),
            file: file,
            confirmation: RestoreConfirmation(
              preview: BackupPreview(
                version: BackupVersion(1),
                createdUtc: p.portabilityCreatedUtc,
                sha256: sha256.convert(file.bytes).toString(),
                recordCounts: const {},
              ),
              expectedSettingsRevision: Revision(1),
            ),
          ),
          isA<Failure<RestoreReceipt>>(),
        );
        expect(
          f.success(await restorer.store.read((r) => r.items())).single.name,
          'Live-only quest',
          reason: 'The original stays readable after a failed restore',
        );
        f.success(
          await items.saveGroup(
            operationId: OperationId(f.uuid(812)),
            group: Group(
              id: GroupId(f.uuid(813)),
              revision: Revision(1),
              name: 'Still writable',
              order: 0,
            ),
            expectedRevision: null,
          ),
        );
      } finally {
        await live?.close();
        await dir.delete(recursive: true);
      }
    });
  }
}
