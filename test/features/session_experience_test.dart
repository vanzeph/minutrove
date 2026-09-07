import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/home/home.dart';
import 'package:minutrove/features/sessions/sessions.dart';
import 'package:minutrove/platform/sessions/session_recovery.dart';
import 'package:minutrove/ui/core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/support.dart' as f;
import '../support/session_fixtures.dart' show configuredQuest;
import 'home_shell_test.dart'
    show HomeFixture, item, flush, settle, waitFor, launcher, capture;

class SessionCommands implements SessionRepository {
  SessionCommands(this.delegate);
  final SessionRepository delegate;
  final operations = <OperationId>[];
  bool losePauseReply = false;
  bool rejectPause = false;
  @override
  Future<Result<Session?>> getSession(SessionId id) => delegate.getSession(id);
  @override
  Future<Result<SessionMutation>> pauseSession({
    required OperationId operationId,
    required SessionId sessionId,
    required Revision expectedRevision,
  }) async {
    operations.add(operationId);
    if (rejectPause) return const Failure(StorageUnavailable(retryable: true));
    final result = await delegate.pauseSession(
      operationId: operationId,
      sessionId: sessionId,
      expectedRevision: expectedRevision,
    );
    if (losePauseReply && operations.length == 1) {
      throw StateError('lost acknowledgement');
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() async {
    await (FontLoader(
      'Nunito Sans',
    )..addFont(rootBundle.load('assets/fonts/NunitoSans.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  late HomeFixture fixture;
  late SessionRecovery recovery;
  late SessionRoute route;
  setUp(() async {
    fixture = HomeFixture();
    await fixture.open();
    recovery = SessionRecovery(
      store: fixture.store,
      sessions: fixture.sessions,
      recordDiagnostic: (_) async {},
    );
    route = SessionRoute(
      sessions: fixture.sessions,
      clock: fixture.clock,
      watchSession: (id) => watchSqliteSession(fixture.store, id),
      reconcile: () => recovery.reconcile(operationId: fixture.op()),
      operationId: fixture.op,
    );
  });
  tearDown(() => fixture.close());

  Future<Session> start({
    bool award = false,
    bool budget = false,
    String name = 'Focus',
  }) async {
    final saved = await fixture.save(
      item(id: 1, name: name, award: award, budget: budget),
    );
    if (award) await fixture.grant(saved);
    return f
        .success(
          await fixture.sessions.startSession(
            operationId: fixture.op(),
            itemId: saved.id,
            expectedItemRevision: saved.revision,
            conflictChoice: SessionConflictChoice.cancel,
          ),
        )
        .session;
  }

  Widget shell() => MinutroveApp(
    home: HomeShell(
      watchHome: () => watchSqliteHome(fixture.store),
      editing: fixture.editing,
      sessions: fixture.sessions,
      clock: fixture.clock,
      routes: HomeRoutes(
        shop: (_) => const Text('Award catalog'),
        stats: (_) => const Text('Activity charts'),
        openSession: route.open,
        openExpense: (_, _, _, _) async {},
      ),
    ),
  );

  Future<void> openCurrent(WidgetTester tester) async {
    await waitFor(
      tester,
      () => find.byType(CompactSessionSlot).evaluate().isNotEmpty,
      'Current session must be loaded',
    );
    final bar = find.byType(CompactSessionBar);
    await tester.tap(bar);
    await settle(tester);
    await waitFor(
      tester,
      () =>
          find.text('Recovering…').evaluate().isEmpty &&
              find.text('Pause session').evaluate().isNotEmpty ||
          find.text('Resume session').evaluate().isNotEmpty,
      'Recovery must finish',
    );
    await settle(tester);
  }

  Future<void> press(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    await settle(tester);
    await flush(tester);
    await waitFor(
      tester,
      () => find
          .byKey(const ValueKey('session-command-progress'))
          .evaluate()
          .isEmpty,
      'Session command must finish',
    );
    await flush(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    await tester.runAsync(fixture.close);
  }

  test('session read model carries fractional earnings and keeps frozen rates with live appearance', () async {
    final quest = await fixture.save(
      configuredQuest(seconds: 3600, coins: 1, gems: 0),
    );
    Future<Session> begin(Revision revision) async => f
        .success(
          await fixture.sessions.startSession(
            operationId: fixture.op(),
            itemId: quest.id,
            expectedItemRevision: revision,
            conflictChoice: SessionConflictChoice.cancel,
          ),
        )
        .session;
    final first = await begin(quest.revision);
    fixture.clock.advance(1800000);
    f.success(
      await fixture.sessions.endSession(
        operationId: fixture.op(),
        sessionId: first.id,
        expectedRevision: first.revision,
      ),
    );
    final second = await begin(quest.revision);
    final edited = await fixture.save(
      Item(
        id: quest.id,
        revision: quest.revision,
        name: 'Renamed activity',
        iconKey: 'book',
        colorArgb: 0xff3265a6,
        groupId: quest.groupId,
        order: quest.order,
        archived: false,
        configuration: QuestConfiguration(
          duration: Milliseconds.seconds(60),
          ratesPerHour: f.amounts(3600000),
        ),
      ),
      create: false,
    );
    fixture.clock.advance(1800000);
    final projected = (await watchSqliteSession(
      fixture.store,
      second.id,
    ).first)!;
    expect(projected.item.name, 'Renamed activity');
    expect(projected.item.iconKey, 'book');
    expect(projected.session.itemSnapshot.revision, quest.revision);
    expect(projected.earningsAt(1800000).coins.units, 1);
    expect(projected.earned.coins.units, 0);
    f.success(
      await fixture.sessions.endSession(
        operationId: fixture.op(),
        sessionId: second.id,
        expectedRevision: second.revision,
      ),
    );
    final committed = (await watchSqliteSession(
      fixture.store,
      second.id,
    ).first)!;
    expect(committed.earned.coins.units, 1);
    expect(committed.earningsAt(1800000).coins.units, 1);
    final third = await begin(edited.revision);
    final fresh = (await watchSqliteSession(fixture.store, third.id).first)!;
    expect(
      fresh.earned.coins.units,
      0,
      reason: 'Past sessions must not appear as earnings for this run',
    );
    expect(fresh.session.duration.value, 60000);
  });

  testWidgets(
    'pause freezes earnings, resume excludes rest, early end returns Home with saved result',
    (tester) async {
      late Session session;
      await tester.runAsync(() async {
        session = await start();
      });
      await tester.pumpWidget(shell());
      await flush(tester);
      await openCurrent(tester);
      fixture.clock.advance(10000);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('0:50'), findsOneWidget);
      expect(find.text('0.01 Coins'), findsOneWidget);
      await press(tester, 'Pause session');
      await waitFor(
        tester,
        () => find.text('Resume session').evaluate().isNotEmpty,
        'Pause must commit',
      );
      fixture.clock.advance(120000);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0:50'), findsOneWidget);
      expect(find.text('0.01 Coins'), findsOneWidget);
      await press(tester, 'Resume session');
      await waitFor(
        tester,
        () => find.text('Pause session').evaluate().isNotEmpty,
        'Resume must commit',
      );
      fixture.clock.advance(5000);
      await press(tester, 'End & keep earnings');
      await waitFor(
        tester,
        () => find.byType(SessionScreen).evaluate().isEmpty,
        'Terminal committed state returns Home',
      );
      await flush(tester);
      expect(find.text('Time well spent'), findsOneWidget);
      await tester.runAsync(() async {
        final saved = f.success(await fixture.sessions.getSession(session.id))!;
        expect(saved.status, SessionStatus.ended);
        expect(saved.settled.value, 15000);
        expect((await fixture.read()).wallet.balances.coins.units, 15000);
      });
      await close(tester);
    },
  );

  testWidgets(
    'close keeps run alive across navigation and completion returns Home only once',
    (tester) async {
      await tester.runAsync(start);
      await tester.pumpWidget(shell());
      await flush(tester);
      await openCurrent(tester);
      await tester.tap(find.byTooltip('Close session view'));
      await settle(tester);
      for (final tab in ['Shop', 'Stats']) {
        await tester.tap(find.text(tab));
        await tester.pump();
        expect(find.text('Running · 1:00'), findsOneWidget);
      }
      fixture.clock.advance(60000);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Finishing · 0:00'), findsOneWidget);
      expect(find.text('Activity charts'), findsOneWidget);
      await tester.runAsync(
        () => recovery.reconcile(operationId: fixture.op()),
      );
      await flush(tester);
      await waitFor(
        tester,
        () => find.text('Time well spent').evaluate().isNotEmpty,
        'Committed completion switches to Home',
      );
      expect(find.byType(CompactSessionSlot), findsNothing);
      await tester.tap(find.text('Shop'));
      await tester.pump();
      await tester.runAsync(
        () => recovery.reconcile(operationId: fixture.op()),
      );
      await flush(tester);
      expect(find.text('Award catalog'), findsOneWidget);
      expect(find.text('Time well spent'), findsNothing);
      await tester.runAsync(() async {
        expect((await fixture.read()).wallet.balances.coins.units, 60000);
      });
      await close(tester);
    },
  );

  testWidgets(
    'paused conflict Cancel preserves slot; confirm settles before next start',
    (tester) async {
      late Session first;
      await tester.runAsync(() async {
        first = await start();
        await fixture.save(item(id: 2, name: 'Read'));
        fixture.clock.advance(10000);
      });
      await tester.pumpWidget(shell());
      await flush(tester);
      await openCurrent(tester);
      await press(tester, 'Pause session');
      await tester.tap(find.byTooltip('Close session view'));
      await settle(tester);
      await tester.tap(launcher('Read'));
      await tester.pump(const Duration(milliseconds: 400));
      await flush(tester);
      expect(find.textContaining('with 0:50 left'), findsOneWidget);
      await press(tester, 'Cancel');
      await tester.runAsync(() async {
        expect((await fixture.read()).activeSession!.id, first.id);
      });
      await tester.tap(launcher('Read'));
      await tester.pump(const Duration(milliseconds: 400));
      await flush(tester);
      fixture.clock.advance(100000);
      await press(tester, 'End current session and continue');
      await waitFor(
        tester,
        () => find.byType(SessionScreen).evaluate().isNotEmpty,
        'Replacement opens new screen',
      );
      await tester.runAsync(() async {
        final data = await fixture.read();
        expect(data.activeSession!.itemSnapshot.name, 'Read');
        expect(data.wallet.balances.coins.units, 10000);
        expect(
          f.success(await fixture.sessions.getSession(first.id))!.status,
          SessionStatus.ended,
        );
      });
      await close(tester);
    },
  );

  testWidgets(
    'timed Award early end retains unused allowance and independent budget',
    (tester) async {
      await tester.runAsync(
        () => start(award: true, budget: true, name: 'Getaway'),
      );
      await tester.pumpWidget(shell());
      await flush(tester);
      await openCurrent(tester);
      fixture.clock.advance(10000);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.textContaining('10s enjoyed'), findsOneWidget);
      expect(find.text('USD 10.00 budget remains'), findsOneWidget);
      await press(tester, 'End & keep remaining time');
      await waitFor(
        tester,
        () => find.byType(SessionScreen).evaluate().isEmpty,
        'Award end returns Home',
      );
      await tester.runAsync(() async {
        final data = await fixture.read();
        expect(data.awards.values.single.time!.value, 50000);
        expect(data.awards.values.single.budget!.minorUnits, 1000);
        expect(data.launchers.single.name, 'Getaway');
      });
      await close(tester);
    },
  );

  testWidgets(
    'lost pause reply retries identical command after committed stream changes',
    (tester) async {
      await tester.runAsync(start);
      final commands = SessionCommands(fixture.sessions)..losePauseReply = true;
      route = SessionRoute(
        sessions: commands,
        clock: fixture.clock,
        watchSession: route.watchSession,
        reconcile: route.reconcile,
        operationId: fixture.op,
      );
      await tester.pumpWidget(shell());
      await flush(tester);
      await openCurrent(tester);
      fixture.clock.advance(10000);
      await press(tester, 'Pause session');
      await waitFor(
        tester,
        () => find.text('Retry action').evaluate().isNotEmpty,
        'Lost reply must offer same-action retry',
      );
      await waitFor(
        tester,
        () => find.text('Resume session').evaluate().isNotEmpty,
        'Committed pause must reach the stream despite the lost reply',
      );
      await press(tester, 'Retry action');
      await waitFor(
        tester,
        () => find.text('Retry action').evaluate().isEmpty,
        'Replay acknowledged',
      );
      expect(commands.operations.length, 2);
      expect(commands.operations.toSet().length, 1);
      await tester.runAsync(() async {
        expect((await fixture.read()).wallet.balances.coins.units, 10000);
      });
      await close(tester);
    },
  );

  testWidgets(
    'failed recovery disables commands until explicit retry reads committed state',
    (tester) async {
      await tester.runAsync(start);
      fixture.clock.unavailable = true;
      await tester.pumpWidget(shell());
      await flush(tester);
      await tester.tap(find.byType(CompactSessionBar));
      await settle(tester);
      await waitFor(
        tester,
        () => find.text('Retry recovery').evaluate().isNotEmpty,
        'Recovery error must be visible',
      );
      expect(
        tester
            .widget<TroveButton>(
              find.widgetWithText(TroveButton, 'Pause session'),
            )
            .onPressed,
        isNull,
      );
      fixture.clock.unavailable = false;
      fixture.clock.advance(10000);
      await press(tester, 'Retry recovery');
      await waitFor(
        tester,
        () => find.text('Recovering…').evaluate().isEmpty,
        'Recovery acknowledged',
      );
      await tester.pump(const Duration(seconds: 1));
      await flush(tester);
      expect(find.text('0:50'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets(
    'completion recovered at route entry exits after committed terminal state',
    (tester) async {
      await tester.runAsync(start);
      await tester.pumpWidget(shell());
      await flush(tester);
      fixture.clock.advance(90000);
      await tester.tap(find.byType(CompactSessionBar));
      await settle(tester);
      await waitFor(
        tester,
        () => find.byType(SessionScreen).evaluate().isEmpty,
        'Recovered completion must return Home',
      );
      await tester.runAsync(() async {
        expect((await fixture.read()).activeSession, isNull);
        expect((await fixture.read()).wallet.balances.coins.units, 60000);
      });
      await close(tester);
    },
  );

  for (final size in [const Size(390, 844), const Size(320, 568)]) {
    testWidgets(
      'session controls and long item name remain accessible at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = size.width == 320
            ? 2
            : 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.runAsync(
          () => start(
            name: size.width == 320
                ? 'A long activity name that wraps'
                : 'Focus',
          ),
        );
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(key: key, child: shell()));
        await flush(tester);
        await openCurrent(tester);
        final semantics = tester.ensureSemantics();
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await capture(tester, key, 'session-running-${size.width.toInt()}');
        await tester.ensureVisible(find.text('Pause session'));
        await tester.pump();
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await press(tester, 'Pause session');
        await waitFor(
          tester,
          () => find.text('Resume session').evaluate().isNotEmpty,
          'Pause receipt',
        );
        await tester.pump(const Duration(milliseconds: 400));
        await capture(
          tester,
          key,
          'session-paused-controls-${size.width.toInt()}',
        );
        await tester.ensureVisible(
          find.text(
            size.width == 320 ? 'A long activity name that wraps' : 'Focus',
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await capture(tester, key, 'session-paused-${size.width.toInt()}');
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await close(tester);
      },
    );
  }
}
