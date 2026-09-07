import 'dart:io';

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
import 'package:minutrove/platform/clock/native_clock.dart';
import 'package:minutrove/platform/sessions/recovery_diagnostics.dart';
import 'package:minutrove/platform/sessions/session_recovery.dart';

import '../test/data/support.dart' as f;
import '../test/support/session_fixtures.dart';

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
    const destinations = {
      'Shop': 'Make room for what you love.',
      'Stats': 'See your time add up.',
      'Home': 'A little effort, a little treasure.',
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
}
