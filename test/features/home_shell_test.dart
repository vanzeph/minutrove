import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/home/home.dart';
import 'package:minutrove/features/items/items.dart';
import 'package:minutrove/ui/core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/support.dart' as f;
import '../support/session_fixtures.dart';

class HomeFixture {
  late Directory directory;
  late SqliteStore store;
  late SqliteItemRepository items;
  late SqliteSessionRepository sessions;
  late ItemEditing editing;
  final clock = SessionClock();
  final calendar = SessionCalendar();
  final openedSessions = <SessionId>[];
  final expenses = <(Item, AwardBalance, SessionConflictChoice)>[];
  var serial = 100;
  OperationId op() => OperationId(f.uuid(serial++));

  Future<void> open() async {
    directory = await Directory.systemTemp.createTemp('minutrove-home-');
    store = f.success(
      await SqliteStore.open(
        path: '${directory.path}/home.db',
        factory: databaseFactoryFfi,
        currencies: f.metadata,
        initialSettings: f.settings,
      ),
    );
    items = SqliteItemRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
    sessions = SqliteSessionRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
    editing = ItemEditing(
      repository: items,
      currencies: f.metadata,
      readFacts: sqliteItemEditFacts(store),
      newUuid: () => f.uuid(serial++),
    );
  }

  bool closed = false;
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await store.close();
    await directory.delete(recursive: true);
  }

  Future<Item> save(Item item, {bool create = true}) async => f.success(
    await items.saveItem(
      operationId: op(),
      item: item,
      expectedRevision: create ? null : item.revision,
    ),
  );
  Future<HomeData> read() async => f.success(
    await store.read(
      (r) async => HomeData(
        items: await r.items(),
        groups: await r.groups(),
        awards: await r.awards(),
        wallet: await r.wallet(),
        activeSession: await r.activeSession(),
      ),
    ),
  );
  Future<int> operationCount() async {
    final db = await databaseFactoryFfi.openDatabase(
      '${directory.path}/home.db',
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      return (await db.rawQuery('SELECT COUNT(*) AS n FROM operations'))
              .single['n']!
          as int;
    } finally {
      await db.close();
    }
  }

  Future<void> grant(Item item, {int time = 60000, int budget = 1000}) async {
    f.success(
      await CommandCoordinator(store).execute<bool>(
        operationId: op(),
        request: CommandRequest(
          kind: OperationKind.redeemAward,
          arguments: {'fixture': serial},
        ),
        committedAt: (_) => calendar.assign(clock.utc, f.zone),
        action: (command) async {
          final config = item.configuration as AwardConfiguration;
          await command.postLedger([
            if (config.timeGrant != null)
              LedgerEntry(
                id: LedgerId(f.uuid(serial++)),
                operationId: command.operationId,
                itemId: item.id,
                itemRevision: item.revision,
                sessionId: null,
                timestamp: calendar.assign(clock.utc, f.zone),
                dimension: const TimeDimension(),
                delta: time,
              ),
            if (config.budgetGrant != null)
              LedgerEntry(
                id: LedgerId(f.uuid(serial++)),
                operationId: command.operationId,
                itemId: item.id,
                itemRevision: item.revision,
                sessionId: null,
                timestamp: calendar.assign(clock.utc, f.zone),
                dimension: BudgetDimension(config.budgetGrant!.currency),
                delta: budget,
              ),
          ]);
          return true;
        },
      ),
    );
  }

  HomeShell shell({
    Stream<HomeData> Function()? watch,
    SessionRepository? sessionCommands,
  }) => HomeShell(
    watchHome: watch ?? () => watchSqliteHome(store),
    editing: editing,
    sessions: sessionCommands ?? sessions,
    clock: clock,
    routes: HomeRoutes(
      shop: (_) => const SingleChildScrollView(child: Text('Award catalog')),
      stats: (_) => const SingleChildScrollView(child: Text('Activity charts')),
      openSession: (_, id, returnHome) async {
        openedSessions.add(id);
      },
      openExpense: (_, item, balance, choice) async {
        expenses.add((item, balance, choice));
      },
    ),
  );
}

class FailFirstStart implements SessionRepository {
  FailFirstStart(this.delegate);
  final SessionRepository delegate;
  final operations = <OperationId>[];
  @override
  Future<Result<SessionMutation>> startSession({
    required OperationId operationId,
    required ItemId itemId,
    required Revision expectedItemRevision,
    required SessionConflictChoice conflictChoice,
  }) async {
    operations.add(operationId);
    if (operations.length == 1) {
      return const Failure(StorageUnavailable(retryable: true));
    }
    return delegate.startSession(
      operationId: operationId,
      itemId: itemId,
      expectedItemRevision: expectedItemRevision,
      conflictChoice: conflictChoice,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Item item({
  required int id,
  required String name,
  bool award = false,
  bool time = true,
  bool budget = false,
  bool archived = false,
  GroupId? group,
  int order = 0,
}) => Item(
  id: ItemId(f.uuid(id)),
  revision: Revision(1),
  name: name,
  iconKey: 'gamepad',
  colorArgb: 0xff7654a5,
  groupId: group,
  order: order,
  archived: archived,
  configuration: award
      ? AwardConfiguration(
          packName: 'Pack',
          price: f.amounts(20),
          timeGrant: time ? Milliseconds.seconds(60) : null,
          budgetGrant: budget
              ? BudgetAmount(
                  BudgetCurrency.fromMetadata('USD', f.metadata),
                  1000,
                )
              : null,
        )
      : QuestConfiguration(
          duration: Milliseconds.seconds(60),
          ratesPerHour: f.amounts(3600000),
        ),
);

Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
  }
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await flush(tester);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> waitFor(
  WidgetTester tester,
  bool Function() ready,
  String reason,
) async {
  for (var attempt = 0; attempt < 100 && !ready(); attempt++) {
    await flush(tester);
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue, reason: reason);
}

Finder launcher(String name) => find
    .descendant(
      of: find.byWidgetPredicate((w) => w is ItemTile && w.name == name),
      matching: find.byType(InkWell),
    )
    .first;
Future<void> single(WidgetTester tester, String name) async {
  await tester.ensureVisible(launcher(name));
  await tester.tap(launcher(name));
  await tester.pump(const Duration(milliseconds: 350));
  await waitFor(
    tester,
    () =>
        find.byType(TroveDialog).evaluate().isNotEmpty ||
        tester
            .widgetList<ItemTile>(find.byType(ItemTile))
            .any((tile) => tile.name == name && tile.onActivate != null),
    'The launch must finish or show its action dialog.',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('Nunito Sans')
      ..addFont(rootBundle.load('assets/fonts/NunitoSans.ttf'));
    await font.load();
    final material = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await material.load();
  });
  sqfliteFfiInit();
  late HomeFixture fixture;
  setUp(() async {
    fixture = HomeFixture();
    await fixture.open();
  });
  tearDown(() async {
    await fixture.close();
  });

  testWidgets('empty Home has a working centered create and layout path', (
    tester,
  ) async {
    await tester.pumpWidget(MinutroveApp(home: fixture.shell()));
    await flush(tester);
    expect(find.text('0 Coins'), findsOneWidget);
    await tester.tap(find.text('Add your first item'));
    await settle(tester);
    expect(find.byType(ItemEditor), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await settle(tester);
    await tester.ensureVisible(find.text('Edit layout · Configure items'));
    await tester.tap(find.text('Edit layout · Configure items'));
    await settle(tester);
    await flush(tester);
    expect(find.byType(GroupManager), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    await tester.runAsync(fixture.close);
  });

  testWidgets(
    'double tap has no session, operation or ledger effect; single starts actual type',
    (tester) async {
      await tester.runAsync(() => fixture.save(item(id: 1, name: 'Focus')));
      final before = await tester.runAsync(() => fixture.operationCount());
      await tester.pumpWidget(MinutroveApp(home: fixture.shell()));
      await flush(tester);
      await tester.tap(launcher('Focus'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(launcher('Focus'));
      await settle(tester);
      await flush(tester);
      expect(find.byType(ItemEditor), findsOneWidget);
      expect(fixture.openedSessions, isEmpty);
      await tester.runAsync(() async {
        expect((await fixture.read()).activeSession, isNull);
        expect(await fixture.operationCount(), before);
        expect(f.success(await fixture.store.read((r) => r.ledger())), isEmpty);
      });
      await tester.tap(find.byTooltip('Close'));
      await settle(tester);
      await tester.tap(launcher('Focus'));
      await tester.pump(const Duration(milliseconds: 150));
      expect(fixture.openedSessions, isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      await flush(tester);
      await waitFor(
        tester,
        () => fixture.openedSessions.length == 1,
        'The committed start must open exactly one session.',
      );
      expect(fixture.openedSessions, hasLength(1));
      await tester.runAsync(() async {
        final data = await fixture.read();
        expect(data.activeSession!.itemSnapshot.type, ItemType.quest);
        expect(data.activeSession!.duration.value, 60000);
      });
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
      await tester.runAsync(fixture.close);
    },
  );

  testWidgets('navigation and Configure invalidate pending single taps', (
    tester,
  ) async {
    await tester.runAsync(() => fixture.save(item(id: 1, name: 'Focus')));
    await tester.pumpWidget(MinutroveApp(home: fixture.shell()));
    await flush(tester);
    await tester.tap(launcher('Focus'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('Shop'));
    await tester.pump(const Duration(milliseconds: 400));
    await flush(tester);
    expect(fixture.openedSessions, isEmpty);
    await tester.tap(find.text('Home'));
    await tester.pump();
    await tester.tap(launcher('Focus'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('Configure'));
    await settle(tester);
    await tester.tap(find.byTooltip('Close'));
    await settle(tester);
    await flush(tester);
    expect(fixture.openedSessions, isEmpty);
    await tester.tap(launcher('Focus'));
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    await tester.runAsync(fixture.close);
    await tester.pump(const Duration(milliseconds: 400));
    expect(fixture.openedSessions, isEmpty);
  });

  testWidgets(
    'mixed groups preserve appearance, pool awards and retain archived balances',
    (tester) async {
      await tester.runAsync(() async {
        final group = f.group(name: 'Make progress');
        f.success(
          await fixture.items.saveGroup(
            operationId: fixture.op(),
            group: group,
            expectedRevision: null,
          ),
        );
        await fixture.save(item(id: 1, name: 'Focus', group: group.id));
        final gaming = await fixture.save(
          item(id: 2, name: 'Gaming', award: true, group: group.id, order: 1),
        );
        await fixture.grant(gaming);
        await fixture.grant(gaming);
        f.success(
          await fixture.items.archiveItem(
            operationId: fixture.op(),
            itemId: gaming.id,
            expectedRevision: gaming.revision,
          ),
        );
        await fixture.save(item(id: 4, name: 'Hidden Quest', archived: true));
        await fixture.save(item(id: 5, name: 'Unowned', award: true));
      });
      await tester.pumpWidget(MinutroveApp(home: fixture.shell()));
      await flush(tester);
      expect(find.text('Make progress'), findsOneWidget);
      expect(find.text('Gaming'), findsOneWidget);
      expect(find.text('Award · 2m'), findsOneWidget);
      expect(find.text('Hidden Quest'), findsNothing);
      expect(find.text('Unowned'), findsNothing);
      final tiles = tester.widgetList<ItemTile>(find.byType(ItemTile)).toList();
      expect(tiles.map((t) => t.kind).toSet(), {
        TileKind.quest,
        TileKind.award,
      });
      expect(tiles.map((t) => t.iconKey).toSet(), {'gamepad'});
      expect(tiles.map((t) => t.palette.accent).toSet(), {
        const Color(0xff7654a5),
      });
      await single(tester, 'Gaming');
      await tester.runAsync(() async {
        final data = await fixture.read();
        expect(data.activeSession!.itemSnapshot.type, ItemType.award);
        expect(data.activeSession!.duration.value, 120000);
      });
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
      await tester.runAsync(fixture.close);
    },
  );

  testWidgets(
    'budget and combined allowance choices route without economic effects',
    (tester) async {
      await tester.runAsync(() async {
        final budget = await fixture.save(
          item(id: 1, name: 'Lunch', award: true, time: false, budget: true),
        );
        final combined = await fixture.save(
          item(id: 2, name: 'Getaway', award: true, budget: true),
        );
        await fixture.grant(budget);
        await fixture.grant(combined, time: 0);
      });
      await tester.pumpWidget(MinutroveApp(home: fixture.shell()));
      await flush(tester);
      await single(tester, 'Lunch');
      expect(fixture.expenses, hasLength(1));
      expect(fixture.expenses.single.$1.name, 'Lunch');
      expect(fixture.expenses.single.$2.budget!.minorUnits, 1000);
      await single(tester, 'Getaway');
      expect(
        tester
            .widget<TroveButton>(find.widgetWithText(TroveButton, 'Use time'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Record expense'));
      await settle(tester);
      await flush(tester);
      expect(fixture.expenses, hasLength(2));
      expect(fixture.openedSessions, isEmpty);
      await tester.runAsync(() async {
        expect((await fixture.read()).activeSession, isNull);
      });
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
      await tester.runAsync(fixture.close);
    },
  );

  testWidgets(
    'paused session persists across tabs; cancel preserves it and confirm replaces atomically',
    (tester) async {
      await tester.runAsync(() async {
        final quest = await fixture.save(item(id: 1, name: 'Focus'));
        await fixture.save(item(id: 2, name: 'Read'));
        final started = f
            .success(
              await fixture.sessions.startSession(
                operationId: fixture.op(),
                itemId: quest.id,
                expectedItemRevision: quest.revision,
                conflictChoice: SessionConflictChoice.cancel,
              ),
            )
            .session;
        fixture.clock.advance(10000);
        f.success(
          await fixture.sessions.pauseSession(
            operationId: fixture.op(),
            sessionId: started.id,
            expectedRevision: started.revision,
          ),
        );
      });
      await tester.pumpWidget(MinutroveApp(home: fixture.shell()));
      await flush(tester);
      for (final tab in ['Shop', 'Stats', 'Home']) {
        await tester.tap(find.text(tab));
        await tester.pump();
        expect(find.text('Paused · 0:50'), findsOneWidget);
        expect(find.text('0.01 Coins'), findsOneWidget);
      }
      fixture.clock.advance(30000);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Paused · 0:50'), findsOneWidget);
      await single(tester, 'Read');
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      await tester.runAsync(() async {
        expect(
          (await fixture.read()).activeSession!.itemSnapshot.name,
          'Focus',
        );
      });
      await single(tester, 'Read');
      await tester.tap(find.text('End current session and continue'));
      await settle(tester);
      await flush(tester);
      await tester.runAsync(() async {
        final data = await fixture.read();
        expect(data.activeSession!.itemSnapshot.name, 'Read');
        expect(data.wallet.balances.coins.units, 10000);
      });
      await waitFor(
        tester,
        () => fixture.openedSessions.length == 1,
        'The committed start must open exactly one session.',
      );
      expect(fixture.openedSessions, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
      await tester.runAsync(fixture.close);
    },
  );

  testWidgets(
    'layout order changes are reflected by Home and persist on reopen',
    (tester) async {
      await tester.runAsync(() async {
        await fixture.save(item(id: 1, name: 'Focus', order: 0));
        await fixture.save(item(id: 2, name: 'Read', order: 1));
      });
      await tester.pumpWidget(MinutroveApp(home: fixture.shell()));
      await flush(tester);
      await tester.ensureVisible(find.text('Edit layout · Configure items'));
      await tester.tap(find.text('Edit layout · Configure items'));
      await settle(tester);
      await flush(tester);
      await tester.ensureVisible(find.byTooltip('Move Read earlier'));
      await tester.tap(find.byTooltip('Move Read earlier'));
      await flush(tester);
      for (
        var i = 0;
        i < 30 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
        i++
      ) {
        await flush(tester);
      }
      await tester.ensureVisible(find.text('Done'));
      await waitFor(
        tester,
        () => find.text('Done').hitTestable().evaluate().isNotEmpty,
        'The saved receipt or layout must finish before Done can be activated.',
      );
      await tester.pump();
      await tester.tap(find.text('Done'));
      await settle(tester);
      await flush(tester);
      expect(find.byType(GroupManager), findsNothing);
      expect(
        tester.widgetList<ItemTile>(find.byType(ItemTile)).map((t) => t.name),
        ['Read', 'Focus'],
      );
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
      await tester.runAsync(() async {
        await fixture.store.close();
        final reopened = f.success(
          await SqliteStore.open(
            path: '${fixture.directory.path}/home.db',
            factory: databaseFactoryFfi,
            currencies: f.metadata,
            initialSettings: f.settings,
          ),
        );
        expect(
          f
              .success(await reopened.read((r) => r.item(ItemId(f.uuid(2)))))!
              .order,
          0,
        );
        await reopened.close();
      });
      await tester.runAsync(fixture.close);
    },
  );

  testWidgets(
    'failed reads offer retry and do not show a fabricated empty wallet',
    (tester) async {
      var attempts = 0;
      Stream<HomeData> watch() {
        attempts++;
        return attempts == 1
            ? Stream<HomeData>.error(const StorageUnavailable(retryable: true))
            : watchSqliteHome(fixture.store);
      }

      await tester.pumpWidget(MinutroveApp(home: fixture.shell(watch: watch)));
      await tester.pump();
      expect(find.text('Retry loading'), findsOneWidget);
      expect(find.text('0 Coins'), findsNothing);
      await tester.tap(find.text('Retry loading'));
      await flush(tester);
      expect(find.text('0 Coins'), findsOneWidget);
      expect(find.text('Add your first item'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
      await tester.runAsync(fixture.close);
    },
  );

  testWidgets(
    'an active combined Award can choose expense without ending on open',
    (tester) async {
      await tester.runAsync(() async {
        final combined = await fixture.save(
          item(id: 1, name: 'Getaway', award: true, budget: true),
        );
        await fixture.grant(combined);
        f.success(
          await fixture.sessions.startSession(
            operationId: fixture.op(),
            itemId: combined.id,
            expectedItemRevision: combined.revision,
            conflictChoice: SessionConflictChoice.cancel,
          ),
        );
      });
      await tester.pumpWidget(MinutroveApp(home: fixture.shell()));
      await flush(tester);
      await single(tester, 'Getaway');
      await tester.tap(find.text('Record expense'));
      await settle(tester);
      await tester.tap(find.text('End current session and continue'));
      await settle(tester);
      expect(
        fixture.expenses.single.$3,
        SessionConflictChoice.endCurrentAndContinue,
      );
      await tester.runAsync(() async {
        final data = await fixture.read();
        expect(data.activeSession!.status, SessionStatus.running);
        expect(data.awards.values.single.budget!.minorUnits, 1000);
      });
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
      await tester.runAsync(fixture.close);
    },
  );

  testWidgets(
    'last timed allowance disappears only after committed consumption',
    (tester) async {
      await tester.runAsync(() async {
        final award = await fixture.save(
          item(id: 1, name: 'Gaming', award: true),
        );
        await fixture.grant(award);
      });
      await tester.pumpWidget(MinutroveApp(home: fixture.shell()));
      await flush(tester);
      await single(tester, 'Gaming');
      fixture.clock.advance(60000);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Finishing · 0:00'), findsOneWidget);
      expect(find.byType(ItemTile), findsOneWidget);
      await tester.runAsync(() async {
        final active = (await fixture.read()).activeSession!;
        f.success(
          await fixture.sessions.reconcileSession(
            operationId: fixture.op(),
            sessionId: active.id,
          ),
        );
      });
      await flush(tester);
      expect(find.byType(ItemTile), findsNothing);
      expect(find.byType(CompactSessionSlot), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
      await tester.runAsync(fixture.close);
    },
  );

  testWidgets(
    'Configure moves an item into its persisted group without changing rates',
    (tester) async {
      await tester.runAsync(() async {
        await fixture.save(item(id: 1, name: 'Focus'));
        f.success(
          await fixture.items.saveGroup(
            operationId: fixture.op(),
            group: f.group(name: 'Make progress'),
            expectedRevision: null,
          ),
        );
      });
      await tester.pumpWidget(MinutroveApp(home: fixture.shell()));
      await flush(tester);
      await tester.tap(find.text('Configure'));
      await settle(tester);
      final dropdown = find.byTooltip('Group');
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await settle(tester);
      await tester.tap(find.text('Make progress').last);
      await settle(tester);
      await tester.ensureVisible(find.text('Save item'));
      await tester.tap(find.text('Save item'));
      await settle(tester);
      for (var i = 0; i < 30 && find.text('Done').evaluate().isEmpty; i++) {
        await flush(tester);
      }
      await tester.ensureVisible(find.text('Done'));
      await waitFor(
        tester,
        () => find.text('Done').hitTestable().evaluate().isNotEmpty,
        'The saved receipt or layout must finish before Done can be activated.',
      );
      await tester.tap(find.text('Done'));
      await settle(tester);
      expect(find.byType(ItemEditor), findsNothing);
      expect(find.text('Make progress'), findsOneWidget);
      expect(find.text('Ungrouped'), findsNothing);
      await tester.runAsync(() async {
        final moved = (await fixture.read()).items.single;
        expect(moved.groupId, f.group().id);
        expect(
          (moved.configuration as QuestConfiguration).ratesPerHour.coins.units,
          3600000,
        );
      });
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
      await tester.runAsync(fixture.close);
    },
  );

  testWidgets('retrying a failed start reuses its operation identity', (
    tester,
  ) async {
    await tester.runAsync(() => fixture.save(item(id: 1, name: 'Focus')));
    final commands = FailFirstStart(fixture.sessions);
    await tester.pumpWidget(
      MinutroveApp(home: fixture.shell(sessionCommands: commands)),
    );
    await flush(tester);
    await single(tester, 'Focus');
    expect(fixture.openedSessions, isEmpty);
    await tester.ensureVisible(find.text('Retry start'));
    await tester.tap(find.text('Retry start'));
    await settle(tester);
    expect(commands.operations, hasLength(2));
    expect(commands.operations.toSet(), hasLength(1));
    expect(fixture.openedSessions, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    await tester.runAsync(fixture.close);
  });

  for (final size in [const Size(390, 844), const Size(320, 568)]) {
    testWidgets(
      'Home renders at $size with accessible navigation and Configure',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = size.width == 320
            ? 2
            : 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.runAsync(() async {
          final group = f.group(name: 'Make progress');
          f.success(
            await fixture.items.saveGroup(
              operationId: fixture.op(),
              group: group,
              expectedRevision: null,
            ),
          );
          await fixture.save(item(id: 1, name: 'Focus', group: group.id));
          final award = await fixture.save(
            item(id: 2, name: 'Gaming', award: true, group: group.id),
          );
          await fixture.grant(award);
        });
        final semantics = tester.ensureSemantics();
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MinutroveApp(home: fixture.shell()),
          ),
        );
        await flush(tester);
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await capture(tester, key, 'home-${size.width.toInt()}');
        await tester.runAsync(() async {
          final quest = (await fixture.read()).items.firstWhere(
            (item) => item.type == ItemType.quest,
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
        await flush(tester);
        expect(tester.takeException(), isNull);
        await capture(tester, key, 'home-active-${size.width.toInt()}');
        await tester.tap(find.text('Shop'));
        await settle(tester);
        expect(find.text('Running · 1:00'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await capture(tester, key, 'shop-active-${size.width.toInt()}');
        semantics.dispose();
        await tester.pumpWidget(const SizedBox());
        await flush(tester);
        await tester.runAsync(fixture.close);
      },
    );
  }
}

Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('UI_EVIDENCE')) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory('build/ui-evidence').createSync(recursive: true);
    File('build/ui-evidence/$name.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
