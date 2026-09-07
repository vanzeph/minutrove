import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
}
