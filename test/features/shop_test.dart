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
import 'package:minutrove/features/shop/shop.dart';
import 'package:minutrove/ui/core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/support.dart' as f;
import 'home_shell_test.dart' show HomeFixture, flush, waitFor, settle;

final usd = BudgetCurrency.fromMetadata('USD', f.metadata);
Item offer({
  int id = 2,
  int revision = 1,
  String name = 'Gaming',
  int coins = 10000000,
  int gems = 1000000,
  int? time = 600000,
  int? budget = 1000,
  bool archived = false,
}) => Item(
  id: ItemId(f.uuid(id)),
  revision: Revision(revision),
  name: name,
  iconKey: 'gamepad',
  colorArgb: 0xff7654a5,
  groupId: null,
  order: id,
  archived: archived,
  configuration: AwardConfiguration(
    packName: 'pack',
    price: f.amounts(coins, gems),
    timeGrant: time == null ? null : Milliseconds(time),
    budgetGrant: budget == null ? null : BudgetAmount(usd, budget),
  ),
);

/// Can deliberately lose the reply AFTER commit, or hold a command in flight.
class ControlledEconomy implements EconomyRepository {
  ControlledEconomy(this.delegate);
  final EconomyRepository delegate;
  final operations = <OperationId>[];
  Completer<void>? gate;
  bool loseFirstReply = false;
  bool failFirst = false;
  @override
  Future<Result<EconomicState>> redeemAward({
    required OperationId operationId,
    required ItemId awardId,
    required Revision expectedRevision,
    required PurchaseQuantity quantity,
  }) async {
    operations.add(operationId);
    if (gate != null) await gate!.future;
    if (failFirst && operations.length == 1) {
      return const Failure(StorageUnavailable(retryable: true));
    }
    final result = await delegate.redeemAward(
      operationId: operationId,
      awardId: awardId,
      expectedRevision: expectedRevision,
      quantity: quantity,
    );
    if (loseFirstReply && operations.length == 1) {
      throw StateError('lost reply');
    }
    return result;
  }

  @override
  Stream<WalletProjection> watchWallet() => delegate.watchWallet();
  @override
  Stream<List<AwardBalance>> watchAwards() => delegate.watchAwards();
  @override
  Future<Result<RedemptionPreview>> previewAward({
    required ItemId awardId,
    required PurchaseQuantity quantity,
  }) => delegate.previewAward(awardId: awardId, quantity: quantity);
  @override
  Future<Result<EconomicState>> recordExpense({
    required OperationId operationId,
    required ItemId awardId,
    required Revision expectedBalanceRevision,
    required BudgetAmount expense,
    required SessionConflictChoice conflictChoice,
  }) => delegate.recordExpense(
    operationId: operationId,
    awardId: awardId,
    expectedBalanceRevision: expectedBalanceRevision,
    expense: expense,
    conflictChoice: conflictChoice,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late HomeFixture fixture;
  late ControlledEconomy economy;
  late Item gaming;

  setUpAll(() async {
    final font = FontLoader('Nunito Sans')
      ..addFont(rootBundle.load('assets/fonts/NunitoSans.ttf'));
    await font.load();
  });
  setUp(() async {
    fixture = HomeFixture();
    await fixture.open();
    economy = ControlledEconomy(
      SqliteEconomyRepository(
        store: fixture.store,
        clock: fixture.clock,
        calendar: fixture.calendar,
      ),
    );
    gaming = await fixture.save(offer());
  });
  tearDown(() => fixture.close());

  void shopTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flush(tester);
        await tester.runAsync(fixture.close);
      }
    });
  }

  Future<void> seed({int coins = 420000000, int gems = 18000000}) async {
    final quest = await fixture.save(f.quest());
    final operation = fixture.op();
    f.success(
      await CommandCoordinator(fixture.store).execute<bool>(
        operationId: operation,
        request: CommandRequest(
          kind: OperationKind.reconcileSession,
          arguments: {'synthetic': operation.value},
        ),
        committedAt: (_) => f.event,
        action: (command) async {
          await command.postLedger([
            for (final entry in [
              (VirtualCurrency.coins, coins),
              (VirtualCurrency.gems, gems),
            ])
              if (entry.$2 > 0)
                LedgerEntry(
                  id: LedgerId(fixture.editing.newUuid()),
                  operationId: operation,
                  itemId: quest.id,
                  itemRevision: quest.revision,
                  sessionId: null,
                  timestamp: f.event,
                  dimension: VirtualCurrencyDimension(entry.$1),
                  delta: entry.$2,
                ),
          ]);
          return true;
        },
      ),
    );
  }

  ShopScreen shop() => ShopScreen(
    watchShop: () => watchSqliteHome(fixture.store),
    economy: economy,
    editing: fixture.editing,
  );

  Future<void> openDialog(WidgetTester tester, {double scale = 1}) async {
    await tester.pumpWidget(
      MinutroveApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showRedemptionDialog(
                  context: context,
                  awardId: gaming.id,
                  watchShop: () => watchSqliteHome(fixture.store),
                  economy: economy,
                  newOperationId: fixture.op,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await settle(tester);
    await waitFor(
      tester,
      () => find.byType(TextField).evaluate().isNotEmpty,
      'Purchase data loads.',
    );
  }

  Future<void> enter(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.byKey(const ValueKey('purchase-quantity')));
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('purchase-submit')));
    await tester.tap(find.byKey(const ValueKey('purchase-submit')));
    await flush(tester);
  }

  shopTest(
    'slider, stepper and exact input share min/max and reject invalid drafts',
    (tester) async {
      await tester.runAsync(() => seed(coins: 30000000, gems: 3000000));
      await openDialog(tester);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Decrease quantity',
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Increase quantity',
        ),
      );
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '2',
      );
      expect(tester.widget<Slider>(find.byType(Slider)).value, .5);
      tester.widget<Slider>(find.byType(Slider)).onChanged!(1);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '3',
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Increase quantity',
              ),
            )
            .onPressed,
        isNull,
      );
      await enter(tester, '1');
      expect(tester.widget<Slider>(find.byType(Slider)).value, 0);
      for (final value in [
        '',
        '0',
        '-1',
        '1.5',
        '1e3',
        '9223372036854775808',
      ]) {
        await enter(tester, value);
        expect(
          find.text('Enter a positive whole number of packs.'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<TroveButton>(
                find.byKey(const ValueKey('purchase-submit')),
              )
              .onPressed,
          isNull,
        );
      }
      expect(economy.operations, isEmpty);
    },
  );

  shopTest(
    'joint price shortages retain quantity and recover to affordable max',
    (tester) async {
      await tester.runAsync(() => seed(gems: 2000000));
      await openDialog(tester);
      await enter(tester, '3');
      expect(find.text('You need 1 more Gem.'), findsOneWidget);
      expect(find.text('Max affordable: 2 packs'), findsOneWidget);
      expect(find.text('You get: 30m + USD 30.00 budget'), findsOneWidget);
      final useMax = find.text('Use affordable quantity · 2');
      await tester.ensureVisible(useMax);
      await tester.tap(useMax);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '2',
      );
      expect(find.textContaining('You need'), findsNothing);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 1);
      expect(economy.operations, isEmpty);
    },
  );

  shopTest(
    'zero wallet reports both shortages; cancellation preserves all data',
    (tester) async {
      final before = await tester.runAsync(fixture.operationCount);
      await openDialog(tester);
      expect(find.text('You need 10 more Coins.'), findsOneWidget);
      expect(find.text('You need 1 more Gem.'), findsOneWidget);
      expect(find.text('Max affordable: 0 packs'), findsOneWidget);
      await tester.ensureVisible(find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(await tester.runAsync(fixture.operationCount), before);
      expect(economy.operations, isEmpty);
    },
  );

  shopTest(
    'purchase updates shared Home wallet and one pooled tile, repeated taps submit once',
    (tester) async {
      await tester.runAsync(() async {
        await seed();
        await fixture.grant(gaming, time: 2700000, budget: 3500);
      });
      Stream<HomeData> watch() => watchSqliteHome(fixture.store);
      await tester.pumpWidget(
        MinutroveApp(
          home: HomeShell(
            watchHome: watch,
            editing: fixture.editing,
            sessions: fixture.sessions,
            clock: fixture.clock,
            routes: HomeRoutes(
              shop: (_) => ShopScreen(
                watchShop: watch,
                economy: economy,
                editing: fixture.editing,
              ),
              stats: (_) => const Text('Stats content'),
              openSession: (_, id, home) async {},
              openExpense: (_, item, balance, conflict) async {},
            ),
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('Shop'));
      await settle(tester);
      await tester.ensureVisible(find.text('Redeem Gaming'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Redeem Gaming'));
      await settle(tester);
      await enter(tester, '3');
      expect(
        find.textContaining('New balance: 1h 15m + USD 65.00 budget.'),
        findsOneWidget,
      );
      economy.gate = Completer<void>();
      final repeat = tester
          .widget<TroveButton>(find.byKey(const ValueKey('purchase-submit')))
          .onPressed!;
      await submit(tester);
      repeat();
      // A stale callback and system Back while pending must not create a second purchase.
      await tester.binding.handlePopRoute();
      expect(find.byType(RedemptionDialog), findsOneWidget);
      expect(economy.operations, hasLength(1));
      economy.gate!.complete();
      await waitFor(
        tester,
        () => find.byType(RedemptionDialog).evaluate().isEmpty,
        'Purchase closes after commit.',
      );
      await settle(tester);
      expect(find.text('390 Coins'), findsOneWidget);
      expect(find.text('15 Gems'), findsOneWidget);
      await tester.tap(find.text('Home'));
      await settle(tester);
      final tiles = tester
          .widgetList<ItemTile>(find.byType(ItemTile))
          .where((t) => t.name == 'Gaming');
      expect(tiles, hasLength(1));
      expect(tiles.single.summary, contains('1h 15m'));
      final state = await tester.runAsync(fixture.read);
      expect(state!.awards[gaming.id]!.time!.value, 4500000);
      expect(state.awards[gaming.id]!.budget!.minorUnits, 6500);
    },
  );

  shopTest('stale quote refresh requires a new explicit confirmation', (
    tester,
  ) async {
    await tester.runAsync(seed);
    await openDialog(tester);
    await enter(tester, '3');
    // Hold the request after the displayed revision was captured, then edit.
    economy.gate = Completer<void>();
    await submit(tester);
    await tester.runAsync(() async {
      await fixture.save(offer(coins: 12000000), create: false);
    });
    economy.gate!.complete();
    await waitFor(
      tester,
      () =>
          find.text('Confirm updated purchase').evaluate().isNotEmpty &&
          find.text('Purchasing…').evaluate().isEmpty,
      'Updated confirmation appears.',
    );
    await flush(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '3',
    );
    expect(find.text('36 Coins'), findsOneWidget);
    expect(
      (await tester.runAsync(fixture.read))!.wallet.balances.coins.units,
      420000000,
    );
    await submit(tester);
    await settle(tester);
    expect(
      (await tester.runAsync(fixture.read))!.wallet.balances.coins.units,
      384000000,
    );
    expect(economy.operations, hasLength(2));
    expect(economy.operations.first, isNot(economy.operations.last));
  });

  shopTest(
    'lost post-commit reply retries same operation without a second debit',
    (tester) async {
      await tester.runAsync(seed);
      economy.loseFirstReply = true;
      await openDialog(tester);
      await enter(tester, '3');
      await submit(tester);
      await waitFor(
        tester,
        () => find.text('Retry purchase').evaluate().isNotEmpty,
        'Retry is shown.',
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      await submit(tester);
      await waitFor(
        tester,
        () => find.byType(RedemptionDialog).evaluate().isEmpty,
        'Replay closes.',
      );
      expect(economy.operations, hasLength(2));
      expect(economy.operations.first, economy.operations.last);
      final state = (await tester.runAsync(fixture.read))!;
      expect(state.wallet.balances.coins.units, 390000000);
      expect(state.awards[gaming.id]!.time!.value, 1800000);
    },
  );

  shopTest(
    'catalog excludes Quests and archived offers, keeps exhausted offers configurable',
    (tester) async {
      await tester.runAsync(() async {
        await seed();
        await fixture.save(offer(id: 3, name: 'Archived', archived: true));
      });
      await tester.pumpWidget(MinutroveApp(home: Scaffold(body: shop())));
      await settle(tester);
      expect(find.text('Gaming'), findsOneWidget);
      expect(find.text('Archived'), findsNothing);
      expect(find.text('Synthetic Quest'), findsNothing);
      expect(find.text('Configure Gaming'), findsOneWidget);
      expect(find.text('Redeem Gaming'), findsOneWidget);
      await tester.ensureVisible(find.text('Configure Gaming'));
      await tester.tap(find.text('Configure Gaming'));
      await settle(tester);
      expect(find.byType(TroveDialog), findsOneWidget);
      expect(economy.operations, isEmpty);
    },
  );

  test(
    'representable quantity also respects pooled time and budget capacity',
    () async {
      await seed(coins: maxStoredInteger, gems: maxStoredInteger);
      await fixture.grant(
        gaming,
        time: maxStoredInteger - 600000,
        budget: 1000,
      );
      final data = await fixture.read();
      final one = PurchaseSummary(data, gaming, 1);
      expect(one.maximumPurchasable, 1);
      expect(one.canPurchase, isTrue);
      expect(PurchaseSummary(data, gaming, 2).overflow, isTrue);
      expect(PurchaseSummary(data, gaming, maxStoredInteger).overflow, isTrue);
    },
  );

  test('a callback from an older painted quote cannot confirm a newly delivered revision', () async {
    await seed();
    final stream = StreamController<HomeData>.broadcast(sync: true);
    final controller = PurchaseController(
      awardId: gaming.id,
      watchShop: () => stream.stream,
      economy: economy,
      newOperationId: fixture.op,
    );
    stream.add(await fixture.read());
    final displayedRevision = controller.item!.revision;
    await fixture.save(offer(coins: 12000000), create: false);
    stream.add(await fixture.read());
    await controller.submit(
      displayedRevision: displayedRevision,
      displayedQuantity: 1,
    );
    expect(economy.operations, isEmpty);
    expect(controller.changed, isTrue);
    await controller.submit(
      displayedRevision: controller.item!.revision,
      displayedQuantity: 1,
    );
    expect(economy.operations, hasLength(1));
    expect(controller.completed!.wallet.balances.coins.units, 408000000);
    controller.dispose();
    await stream.close();
  });

  shopTest(
    'wallet changes after preview cannot overdraw, and quantity is retained',
    (tester) async {
      await tester.runAsync(() => seed(coins: 30000000, gems: 3000000));
      await openDialog(tester);
      await enter(tester, '3');
      economy.gate = Completer<void>();
      await submit(tester);
      await tester.runAsync(() async {
        f.success(
          await economy.delegate.redeemAward(
            operationId: fixture.op(),
            awardId: gaming.id,
            expectedRevision: gaming.revision,
            quantity: PurchaseQuantity(1),
          ),
        );
      });
      economy.gate!.complete();
      await waitFor(
        tester,
        () => find.text('Use affordable quantity · 2').evaluate().isNotEmpty,
        'Latest wallet offers an affordable quantity.',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '3',
      );
      final state = (await tester.runAsync(fixture.read))!;
      expect(state.wallet.balances.coins.units, 20000000);
      expect(state.awards[gaming.id]!.time!.value, 600000);
    },
  );

  shopTest(
    'purchase remains available during an active session and does not replace it',
    (tester) async {
      await tester.runAsync(() async {
        await seed();
        f.success(
          await fixture.sessions.startSession(
            operationId: fixture.op(),
            itemId: f.quest().id,
            expectedItemRevision: Revision(1),
            conflictChoice: SessionConflictChoice.cancel,
          ),
        );
      });
      final active = (await tester.runAsync(fixture.read))!.activeSession!;
      await openDialog(tester);
      await submit(tester);
      await waitFor(
        tester,
        () => find.byType(RedemptionDialog).evaluate().isEmpty,
        'Purchase commits while active.',
      );
      final state = (await tester.runAsync(fixture.read))!;
      expect(state.activeSession!.id, active.id);
      expect(state.activeSession!.revision, active.revision);
      expect(state.awards[gaming.id]!.time!.value, 600000);
    },
  );

  shopTest(
    'archiving during dialog hides purchase without deleting owned allowance',
    (tester) async {
      await tester.runAsync(() async {
        await seed();
        await fixture.grant(gaming);
      });
      await openDialog(tester);
      await tester.runAsync(() async {
        f.success(
          await fixture.items.archiveItem(
            operationId: fixture.op(),
            itemId: gaming.id,
            expectedRevision: gaming.revision,
          ),
        );
      });
      await flush(tester);
      expect(
        find.text('This Award is no longer available for purchase.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TroveButton>(find.byKey(const ValueKey('purchase-submit')))
            .onPressed,
        isNull,
      );
      expect(
        (await tester.runAsync(fixture.read))!.awards[gaming.id]!.isExhausted,
        isFalse,
      );
      expect(economy.operations, isEmpty);
    },
  );

  shopTest('read failures disable stale catalog and retry recovers', (
    tester,
  ) async {
    var failed = true;
    Stream<HomeData> watch() {
      if (failed) throw StateError('unavailable');
      return watchSqliteHome(fixture.store);
    }

    await tester.pumpWidget(
      MinutroveApp(
        home: Scaffold(
          body: ShopScreen(
            watchShop: watch,
            economy: economy,
            editing: fixture.editing,
          ),
        ),
      ),
    );
    await settle(tester);
    expect(
      find.text('Could not load the catalog and balances.'),
      findsOneWidget,
    );
    expect(find.text('Redeem Gaming'), findsNothing);
    failed = false;
    await tester.tap(find.text('Retry loading Shop'));
    await settle(tester);
    expect(find.text('Redeem Gaming'), findsOneWidget);
  });

  test('single-dimension and micro-priced previews retain exact amounts and 64-bit bounds', () async {
    await seed(coins: maxStoredInteger, gems: 0);
    final data = await fixture.read();
    final time = PurchaseSummary(
      data,
      offer(coins: 1, gems: 0, time: null, budget: 1),
      maxStoredInteger,
    );
    expect(time.maximumAffordable, maxStoredInteger);
    expect(time.canPurchase, isTrue);
    expect(time.total!.coins.units, maxStoredInteger);
    expect(time.after!.coins.units, 0);
    expect(time.time, isNull);
    expect(time.budget!.minorUnits, maxStoredInteger);
    final budget = PurchaseSummary(
      data,
      offer(coins: 3, gems: 0, time: null),
      2,
    );
    expect(budget.time, isNull);
    expect(budget.budget!.minorUnits, 2000);
    expect(budget.total!.coins.units, 6);
  });

  for (final size in [const Size(390, 844), const Size(320, 640)]) {
    shopTest(
      'shop and keyboard dialog fit ${size.width} with large text and labeled targets',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final scale = size.width == 320 ? 2.0 : 1.0;
        await tester.runAsync(seed);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: TroveTokens.theme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(body: shop()),
            ),
          ),
        );
        await settle(tester);
        await capture(tester, key, 'shop-${size.width.toInt()}');
        await tester.ensureVisible(find.text('Redeem Gaming'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Redeem Gaming'));
        await settle(tester);
        await enter(tester, '3');
        final semantics = tester.ensureSemantics();
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        semantics.dispose();
        expect(tester.takeException(), isNull);
        await tester.drag(
          find.byType(SingleChildScrollView).last,
          const Offset(0, 2000),
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await capture(tester, key, 'redeem-${size.width.toInt()}');
        tester.view.viewInsets = const FakeViewPadding(bottom: 220);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Cancel'));
        await tester.pumpAndSettle();
        await capture(tester, key, 'redeem-keyboard-${size.width.toInt()}');
        await tester.tap(find.text('Cancel'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(economy.operations, isEmpty);
        expect(find.byType(RedemptionDialog), findsNothing);
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
