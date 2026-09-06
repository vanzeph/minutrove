import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/home/home.dart';
import 'package:minutrove/ui/core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/support.dart' as f;
import 'home_shell_test.dart' as h;

class ExpenseProxy implements EconomyRepository {
  ExpenseProxy(
    this.delegate, {
    this.loseFirstResponse = false,
    this.staleFirst = false,
  });
  final EconomyRepository delegate;
  final bool loseFirstResponse;
  final bool staleFirst;
  final operations = <OperationId>[];
  Completer<void>? gate;
  @override
  Future<Result<EconomicState>> recordExpense({
    required OperationId operationId,
    required ItemId awardId,
    required Revision expectedBalanceRevision,
    required BudgetAmount expense,
    required SessionConflictChoice conflictChoice,
  }) async {
    operations.add(operationId);
    await gate?.future;
    if (staleFirst && operations.length == 1) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return const Failure(StaleRevision());
    }
    final result = await delegate.recordExpense(
      operationId: operationId,
      awardId: awardId,
      expectedBalanceRevision: expectedBalanceRevision,
      expense: expense,
      conflictChoice: conflictChoice,
    );
    if (loseFirstResponse && operations.length == 1) {
      throw StateError('Lost acknowledgement');
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
  late h.HomeFixture fixture;
  late Item food;
  late SqliteEconomyRepository economy;
  setUp(() async {
    fixture = h.HomeFixture();
    await fixture.open();
    food = await fixture.save(
      h.item(id: 1, name: 'Food', award: true, time: false, budget: true),
    );
    await fixture.grant(food, budget: 3500);
    economy = SqliteEconomyRepository(
      store: fixture.store,
      clock: fixture.clock,
      calendar: fixture.calendar,
    );
  });
  tearDown(() => fixture.close());

  Widget shell({
    EconomyRepository? commands,
    Stream<HomeData> Function()? watch,
    Future<Result<HomeData>> Function()? read,
  }) {
    final expense = AwardExpenseRoute(
      economy: commands ?? economy,
      watchHome: watch ?? () => watchSqliteHome(fixture.store),
      readHome: read ?? () => readSqliteHome(fixture.store),
      operationId: fixture.op,
    );
    return HomeShell(
      watchHome: () => watchSqliteHome(fixture.store),
      editing: fixture.editing,
      sessions: fixture.sessions,
      clock: fixture.clock,
      routes: HomeRoutes(
        shop: (_) => const Text('Shop catalog'),
        stats: (_) => const Text('History'),
        openSession: (_, id, _) async {
          fixture.openedSessions.add(id);
        },
        openExpense: expense.open,
      ),
    );
  }

  Future<void> launch(WidgetTester tester, {Widget? home}) async {
    await tester.pumpWidget(MinutroveApp(home: home ?? shell()));
    await h.flush(tester);
    await h.single(tester, 'Food');
    await h.settle(tester);
    expect(find.byType(AwardExpenseDialog), findsOneWidget);
  }

  Future<void> amount(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.byType(TextFormField));
    await tester.enterText(find.byType(TextFormField), text);
    await tester.pump();
  }

  Future<void> press(WidgetTester tester, String text) async {
    await h.waitFor(
      tester,
      () => tester
          .widgetList<TroveButton>(find.widgetWithText(TroveButton, text))
          .any((button) => button.onPressed != null),
      'The expected action must be ready: $text',
    );
    await tester.ensureVisible(find.text(text));
    await tester.tap(find.text(text));
    await h.settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await h.flush(tester);
    await tester.runAsync(fixture.close);
  }

  Future<void> recorded(WidgetTester tester) => h.waitFor(
    tester,
    () => find.text('Expense recorded').evaluate().isNotEmpty,
    'Expense command must show its durable receipt.',
  );

  testWidgets(
    'actual expense previews and commits 35.00 minus 12.50 with one Home tile',
    (tester) async {
      await launch(tester);
      await amount(tester, '12.50');
      expect(find.text('USD 22.50 stays in My Trove'), findsOneWidget);
      await press(tester, 'Record USD 12.50');
      await recorded(tester);
      await press(tester, 'Done');
      await tester.runAsync(() async {
        expect(
          (await fixture.read()).awards[food.id]!.budget!.minorUnits,
          2250,
        );
        expect((await fixture.read()).launchers, hasLength(1));
      });
      expect(find.text('Award · USD 22.50'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'invalid and over-budget inputs remain editable; exact balance exhausts but preserves history',
    (tester) async {
      await launch(tester);
      for (final value in [
        '40.00',
        '0',
        '-1',
        'NaN',
        '1.001',
        '1e1',
        '99999999999999999999999999',
      ]) {
        await amount(tester, value);
        await press(tester, 'Record expense');
        await h.waitFor(
          tester,
          () => find.text('Recording…').evaluate().isEmpty,
          'Invalid expense validation finishes without a command.',
        );
        expect(find.byType(AwardExpenseDialog), findsOneWidget);
        expect(
          tester
              .widget<TextFormField>(find.byType(TextFormField))
              .controller!
              .text,
          value,
        );
        await tester.runAsync(() async {
          expect(
            (await fixture.read()).awards[food.id]!.budget!.minorUnits,
            3500,
          );
        });
      }
      await amount(tester, '35.00');
      await press(tester, 'Record USD 35.00');
      await recorded(tester);
      expect(find.textContaining('history are retained'), findsOneWidget);
      await press(tester, 'Done');
      expect(find.byType(ItemTile), findsNothing);
      await tester.runAsync(() async {
        final data = await fixture.read();
        expect(data.items.single.id, food.id);
        expect(data.awards[food.id]!.budget!.minorUnits, 0);
        final entries = f.success(await fixture.store.read((r) => r.ledger()));
        expect(entries.where((e) => e.delta < 0), hasLength(1));
      });
      await finish(tester);
    },
  );

  testWidgets(
    'opening, cancelling, and double tapping never spend or end a paused session',
    (tester) async {
      await tester.runAsync(() async {
        final quest = await fixture.save(h.item(id: 2, name: 'Focus'));
        final session = f
            .success(
              await fixture.sessions.startSession(
                operationId: fixture.op(),
                itemId: quest.id,
                expectedItemRevision: quest.revision,
                conflictChoice: SessionConflictChoice.cancel,
              ),
            )
            .session;
        f.success(
          await fixture.sessions.pauseSession(
            operationId: fixture.op(),
            sessionId: session.id,
            expectedRevision: session.revision,
          ),
        );
      });
      await launch(tester);
      await amount(tester, '12.50');
      await press(tester, 'Record USD 12.50');
      expect(find.text('A session is already active'), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await h.settle(tester);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        '12.50',
      );
      await press(tester, 'Cancel');
      await tester.runAsync(() async {
        final data = await fixture.read();
        expect(data.activeSession!.status, SessionStatus.paused);
        expect(data.awards[food.id]!.budget!.minorUnits, 3500);
      });
      await tester.tap(h.launcher('Food'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(h.launcher('Food'));
      await h.settle(tester);
      expect(find.text('Configure item'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'combined Award settles active time and expense only after explicit confirmation',
    (tester) async {
      late Item getaway;
      await tester.runAsync(() async {
        getaway = await fixture.save(
          h.item(id: 2, name: 'Getaway', award: true, budget: true),
        );
        await fixture.grant(getaway, time: 60000, budget: 3500);
      });
      await tester.pumpWidget(MinutroveApp(home: shell()));
      await h.flush(tester);
      await h.single(tester, 'Getaway');
      await press(tester, 'Use time');
      await h.waitFor(
        tester,
        () => fixture.openedSessions.isNotEmpty,
        'Timed award starts directly.',
      );
      fixture.clock.advance(10000);
      await h.single(tester, 'Getaway');
      await press(tester, 'Record expense');
      await amount(tester, '35.00');
      await press(tester, 'Record USD 35.00');
      await press(tester, 'End current session and continue');
      await recorded(tester);
      await tester.runAsync(() async {
        final data = await fixture.read();
        expect(data.activeSession, isNull);
        expect(data.awards[getaway.id]!.time!.value, 50000);
        expect(data.awards[getaway.id]!.budget!.minorUnits, 0);
        expect(data.launchers.map((i) => i.id), contains(getaway.id));
      });
      await press(tester, 'Done');
      await h.single(tester, 'Getaway');
      expect(
        tester
            .widget<TroveButton>(
              find.widgetWithText(TroveButton, 'Record expense'),
            )
            .onPressed,
        isNull,
      );
      await finish(tester);
    },
  );

  testWidgets('consent cannot end a replacement session', (tester) async {
    late Item quest;
    await tester.runAsync(() async {
      quest = await fixture.save(h.item(id: 2, name: 'Focus'));
      f.success(
        await fixture.sessions.startSession(
          operationId: fixture.op(),
          itemId: quest.id,
          expectedItemRevision: quest.revision,
          conflictChoice: SessionConflictChoice.cancel,
        ),
      );
    });
    await launch(tester);
    await amount(tester, '12.50');
    await press(tester, 'Record USD 12.50');
    await tester.runAsync(() async {
      final active = (await fixture.read()).activeSession!;
      f.success(
        await fixture.sessions.endSession(
          operationId: fixture.op(),
          sessionId: active.id,
          expectedRevision: active.revision,
        ),
      );
      f.success(
        await fixture.sessions.startSession(
          operationId: fixture.op(),
          itemId: quest.id,
          expectedItemRevision: quest.revision,
          conflictChoice: SessionConflictChoice.cancel,
        ),
      );
    });
    await press(tester, 'End current session and continue');
    await h.waitFor(
      tester,
      () => find.textContaining('active session changed').evaluate().isNotEmpty,
      'Changed consent is rejected.',
    );
    expect(find.textContaining('active session changed'), findsOneWidget);
    await tester.runAsync(() async {
      expect((await fixture.read()).awards[food.id]!.budget!.minorUnits, 3500);
    });
    await finish(tester);
  });

  testWidgets(
    'lost committed response retries the identical operation without duplicate expense',
    (tester) async {
      final proxy = ExpenseProxy(economy, loseFirstResponse: true);
      await launch(tester, home: shell(commands: proxy));
      await amount(tester, '12.50');
      await press(tester, 'Record USD 12.50');
      await h.waitFor(
        tester,
        () => find.text('Retry expense').evaluate().isNotEmpty,
        'Lost response offers the same request.',
      );
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
        false,
      );
      await press(tester, 'Retry expense');
      await recorded(tester);
      expect(proxy.operations.toSet(), hasLength(1));
      await tester.runAsync(() async {
        expect(
          (await fixture.read()).awards[food.id]!.budget!.minorUnits,
          2250,
        );
      });
      await finish(tester);
    },
  );

  testWidgets(
    'rapid repeated taps and close during submission cannot duplicate or dismiss the write',
    (tester) async {
      final proxy = ExpenseProxy(economy)..gate = Completer<void>();
      await launch(tester, home: shell(commands: proxy));
      await amount(tester, '12.50');
      await press(tester, 'Record USD 12.50');
      await h.waitFor(
        tester,
        () => proxy.operations.isNotEmpty,
        'Write reaches the command.',
      );
      expect(
        tester
            .widget<TroveButton>(find.widgetWithText(TroveButton, 'Recording…'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('Close'), warnIfMissed: false);
      await tester.pump();
      expect(find.byType(AwardExpenseDialog), findsOneWidget);
      proxy.gate!.complete();
      await recorded(tester);
      expect(proxy.operations, hasLength(1));
      await finish(tester);
    },
  );

  testWidgets(
    'stale revision preserves amount and allows explicit resubmission',
    (tester) async {
      final proxy = ExpenseProxy(economy, staleFirst: true);
      await launch(tester, home: shell(commands: proxy));
      await amount(tester, '12.50');
      await press(tester, 'Record USD 12.50');
      await h.waitFor(
        tester,
        () => find.textContaining('allowance changed').evaluate().isNotEmpty,
        'Wait for the delayed stale-revision response before inspecting preserved input.',
      );
      expect(find.textContaining('allowance changed'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        '12.50',
      );
      await press(tester, 'Record USD 12.50');
      await recorded(tester);
      expect(proxy.operations.toSet(), hasLength(2));
      await finish(tester);
    },
  );

  testWidgets(
    'archived purchased budget is usable and stays archived after exhaustion',
    (tester) async {
      await tester.runAsync(() async {
        f.success(
          await fixture.items.archiveItem(
            operationId: fixture.op(),
            itemId: food.id,
            expectedRevision: food.revision,
          ),
        );
      });
      await launch(tester);
      await amount(tester, '35.00');
      await press(tester, 'Record USD 35.00');
      await recorded(tester);
      await tester.runAsync(() async {
        expect((await fixture.read()).item(food.id)!.archived, true);
      });
      await finish(tester);
    },
  );

  testWidgets('read failure keeps input and recovers without a command', (
    tester,
  ) async {
    var failed = true;
    final proxy = ExpenseProxy(economy);
    await launch(
      tester,
      home: shell(
        commands: proxy,
        read: () async => failed
            ? const Failure(StorageUnavailable(retryable: true))
            : Success(await fixture.read()),
      ),
    );
    await amount(tester, '12.50');
    await press(tester, 'Record USD 12.50');
    await h.waitFor(
      tester,
      () => find.textContaining('amount is kept').evaluate().isNotEmpty,
      'Fresh read failure is visible before checking recovery.',
    );
    expect(find.textContaining('amount is kept'), findsOneWidget);
    expect(proxy.operations, isEmpty);
    failed = false;
    await press(tester, 'Retry loading');
    await press(tester, 'Record USD 12.50');
    await recorded(tester);
    await finish(tester);
  });

  testWidgets(
    'combined chooser updates live balances and Configure has no economic effect',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Item getaway;
      await tester.runAsync(() async {
        getaway = await fixture.save(
          h.item(id: 2, name: 'Getaway', award: true, budget: true),
        );
        await fixture.grant(getaway, time: 0, budget: 3500);
      });
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MinutroveApp(home: shell()),
        ),
      );
      await h.flush(tester);
      await h.single(tester, 'Getaway');
      expect(find.text('No time remains.'), findsOneWidget);
      expect(find.text('USD 35.00 available'), findsOneWidget);
      await tester.runAsync(() async {
        await fixture.grant(getaway, time: 60000, budget: 0);
      });
      await h.waitFor(
        tester,
        () => find.text('1m available').evaluate().isNotEmpty,
        'The open choice observes newly purchased time.',
      );
      expect(
        tester
            .widget<TroveButton>(find.widgetWithText(TroveButton, 'Use time'))
            .onPressed,
        isNotNull,
      );
      await tester.pump(const Duration(milliseconds: 350));
      await h.capture(tester, key, 'award-combined');
      late int before;
      await tester.runAsync(() async {
        before = await fixture.operationCount();
      });
      await press(tester, 'Configure Getaway');
      expect(find.text('Configure item'), findsOneWidget);
      await tester.runAsync(() async {
        expect(await fixture.operationCount(), before);
      });
      await finish(tester);
    },
  );

  testWidgets(
    'new session while expense is open requires consent; invalid expense cannot end it',
    (tester) async {
      await launch(tester);
      await tester.runAsync(() async {
        final quest = await fixture.save(h.item(id: 2, name: 'Focus'));
        f.success(
          await fixture.sessions.startSession(
            operationId: fixture.op(),
            itemId: quest.id,
            expectedItemRevision: quest.revision,
            conflictChoice: SessionConflictChoice.cancel,
          ),
        );
      });
      await amount(tester, '40.00');
      await press(tester, 'Record expense');
      await h.waitFor(
        tester,
        () => find.text('Recording…').evaluate().isEmpty,
        'Validation finishes.',
      );
      expect(find.text('A session is already active'), findsNothing);
      await amount(tester, '12.50');
      await press(tester, 'Record USD 12.50');
      await h.waitFor(
        tester,
        () => find.text('A session is already active').evaluate().isNotEmpty,
        'Newly occupied slot requires confirmation.',
      );
      await tester.runAsync(() async {
        expect(
          (await fixture.read()).activeSession!.status,
          SessionStatus.running,
        );
      });
      await finish(tester);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets('expense keyboard and accessibility at 320 wide $scale text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final semantics = tester.ensureSemantics();
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MinutroveApp(home: shell()),
        ),
      );
      await h.flush(tester);
      await h.single(tester, 'Food');
      await h.settle(tester);
      await amount(tester, '12.50');
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await h.capture(tester, key, 'award-expense-$scale');
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(find.text('Record USD 12.50'));
      await tester.pump();
      await h.capture(tester, key, 'award-expense-keyboard-$scale');
      expect(tester.takeException(), isNull);
      await press(tester, 'Record USD 12.50');
      await recorded(tester);
      semantics.dispose();
      await finish(tester);
    });
  }
}
