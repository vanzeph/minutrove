import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/items/items.dart';
import 'package:minutrove/ui/core/core.dart';

import '../data/support.dart' as f;

class MemoryItems implements ItemRepository {
  final items = <Item>[];
  final groups = <Group>[];
  final changes = StreamController<void>.broadcast();
  final saveOperations = <OperationId>[];
  final archived = <ItemId>[];
  DomainError? failNext;
  bool history = false;
  bool active = false;
  DailyGoalRevision? goal;
  Completer<Result<Item>>? pending;
  @override
  Future<Result<Item?>> getItem(ItemId id) async =>
      Success(items.where((i) => i.id == id).firstOrNull);
  @override
  Stream<List<Item>> watchItems() async* {
    yield List.of(items);
    yield* changes.stream.map((_) => List.of(items));
  }

  @override
  Stream<List<Group>> watchGroups() async* {
    yield List.of(groups);
    yield* changes.stream.map((_) => List.of(groups));
  }

  Future<Result<ItemEditFacts>> facts(ItemId id) async => Success(
    ItemEditFacts(hasHistory: history, active: active, latestGoal: goal),
  );
  @override
  Future<Result<Item>> saveItem({
    required OperationId operationId,
    required Item item,
    required Revision? expectedRevision,
  }) async {
    saveOperations.add(operationId);
    if (pending != null) return pending!.future;
    final error = failNext;
    failNext = null;
    if (error != null) return Failure(error);
    final previous = items.where((i) => i.id == item.id).firstOrNull;
    if (previous != null) {
      final check = validateItemEdit(
        previous: previous,
        proposed: item,
        expectedRevision: expectedRevision!,
        hasHistory: history,
        hasActiveSession: active,
      );
      if (check is Failure<Item>) return check;
    }
    final saved = Item(
      id: item.id,
      revision: previous?.revision.next() ?? Revision(1),
      name: item.name,
      iconKey: item.iconKey,
      colorArgb: item.colorArgb,
      groupId: item.groupId,
      order: item.order,
      archived: item.archived,
      configuration: item.configuration,
    );
    items.removeWhere((i) => i.id == saved.id);
    items.add(saved);
    changes.add(null);
    return Success(saved);
  }

  @override
  Future<Result<Item>> archiveItem({
    required OperationId operationId,
    required ItemId itemId,
    required Revision expectedRevision,
  }) async {
    if (active) return const Failure(ActiveSessionConflict());
    archived.add(itemId);
    final item = items.firstWhere((i) => i.id == itemId);
    return saveItem(
      operationId: operationId,
      expectedRevision: expectedRevision,
      item: Item(
        id: item.id,
        revision: item.revision,
        name: item.name,
        iconKey: item.iconKey,
        colorArgb: item.colorArgb,
        groupId: item.groupId,
        order: item.order,
        archived: true,
        configuration: item.configuration,
      ),
    );
  }

  @override
  Future<Result<Group>> saveGroup({
    required OperationId operationId,
    required Group group,
    required Revision? expectedRevision,
  }) async {
    final saved = Group(
      id: group.id,
      revision: expectedRevision?.next() ?? Revision(1),
      name: group.name,
      order: group.order,
    );
    groups.removeWhere((g) => g.id == saved.id);
    groups.add(saved);
    changes.add(null);
    return Success(saved);
  }

  @override
  Future<Result<List<Item>>> removeGroup({
    required OperationId operationId,
    required GroupId groupId,
    required Revision expectedRevision,
  }) async {
    groups.removeWhere((g) => g.id == groupId);
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.groupId != groupId) continue;
      items[i] = Item(
        id: item.id,
        revision: item.revision.next(),
        name: item.name,
        iconKey: item.iconKey,
        colorArgb: item.colorArgb,
        groupId: null,
        order: item.order,
        archived: item.archived,
        configuration: item.configuration,
      );
    }
    changes.add(null);
    return Success(List.of(items));
  }
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
  late MemoryItems repo;
  late ItemEditing editing;
  var serial = 100;
  setUp(() {
    repo = MemoryItems();
    editing = ItemEditing(
      repository: repo,
      currencies: f.metadata,
      readFacts: repo.facts,
      newUuid: () => f.uuid(serial++),
    );
  });
  tearDown(() => repo.changes.close());

  Future<void> open(
    WidgetTester tester, {
    Item? item,
    bool groups = false,
    GlobalKey? boundary,
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: TroveTokens.theme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => groups
                    ? showGroupManager(context: context, editing: editing)
                    : showItemEditor(
                        context: context,
                        editing: editing,
                        item: item,
                      ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder.last);
    await tester.pumpAndSettle();
    await tester.tap(finder.last);
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, String label, String text) async {
    final field = find.descendant(
      of: find.byKey(ValueKey(label)),
      matching: find.byType(TextFormField),
    );
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, text);
    await tester.pump();
  }

  Future<void> choose(WidgetTester tester, String label, String option) async {
    await tap(tester, find.byTooltip(label));
    await tap(tester, find.text(option).last);
  }

  testWidgets('creates multiple Quests; invalid input and cancel never write', (
    tester,
  ) async {
    await open(tester);
    await enter(tester, 'Item name', 'Read');
    await enter(tester, 'Session countdown', '1.5');
    await enter(tester, 'Coins earned', '-1');
    await tap(tester, find.text('Save item'));
    expect(repo.saveOperations, isEmpty);
    await enter(tester, 'Coins earned', '2');
    await tap(tester, find.text('Save item'));
    expect(repo.items.single.name, 'Read');
    expect(
      (repo.items.single.configuration as QuestConfiguration)
          .ratesPerHour
          .coins
          .units,
      120000000,
    );
    await tap(tester, find.text('Done'));
    await tap(tester, find.text('Open'));
    await enter(tester, 'Item name', 'Write');
    await enter(tester, 'Session countdown', '2');
    await enter(tester, 'Gems earned', '0.04');
    await tap(tester, find.text('Save item'));
    expect(repo.items.length, 2);
    await tap(tester, find.text('Done'));
    await tap(tester, find.text('Open'));
    await enter(tester, 'Item name', 'Cancelled');
    await tap(tester, find.text('Cancel'));
    expect(repo.items.length, 2);
  });

  for (final kind in ['time', 'budget', 'combined']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'creates $kind Award at ${scale}x with correct currency precision',
        (tester) async {
          tester.view.physicalSize = Size(
            scale == 1 ? 390 : 320,
            scale == 1 ? 844 : 568,
          );
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final boundary = GlobalKey();
          await open(tester, boundary: boundary);
          await choose(tester, 'Type', 'Award');
          await enter(tester, 'Item name', 'Reward');
          await enter(tester, 'Purchase pack name', 'One pack');
          if (kind != 'budget') {
            await enter(tester, 'Time per pack', '10');
          } else {
            await tap(tester, find.text('Grant time'));
          }
          if (kind != 'time') {
            await tap(tester, find.text('Grant spending budget'));
            await enter(tester, 'Budget currency', 'USD');
            await enter(tester, 'Budget per pack', '12.50');
          }
          await enter(tester, 'Pack price · Coins', '2.000001');
          await enter(tester, 'Pack price · Gems', '0.04');
          await tester.ensureVisible(find.text('Save item'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (kind == 'combined') {
            await capture(tester, boundary, 'award-${scale}x');
          }
          await tap(tester, find.text('Save item'));
          final award = repo.items.single.configuration as AwardConfiguration;
          expect(award.timeGrant?.value, kind == 'budget' ? null : 600000);
          expect(award.budgetGrant?.minorUnits, kind == 'time' ? null : 1250);
          expect(award.price.coins.units, 2000001);
          expect(award.price.gems.units, 40000);
        },
      );
    }
  }

  testWidgets(
    'type switches and nested picker cancellation retain every draft section',
    (tester) async {
      await open(tester);
      await enter(tester, 'Item name', 'Keep draft');
      await enter(tester, 'Session countdown', '45');
      await choose(tester, 'Type', 'Award');
      await enter(tester, 'Purchase pack name', 'Keep pack');
      await choose(tester, 'Type', 'Quest');
      expect(find.text('45'), findsOneWidget);
      await tap(tester, find.text('Choose color'));
      await tap(tester, find.text('Cancel'));
      expect(find.text('Keep draft'), findsOneWidget);
      await choose(tester, 'Type', 'Award');
      expect(find.text('Keep pack'), findsOneWidget);
      expect(repo.saveOperations, isEmpty);
    },
  );

  testWidgets(
    'storage retry reuses operation, prevents duplicate taps and preserves draft',
    (tester) async {
      final item = f.quest();
      repo.items.add(item);
      repo.failNext = const StorageUnavailable(retryable: true);
      await open(tester, item: item);
      await enter(tester, 'Item name', 'Retained');
      await tap(tester, find.text('Save item'));
      expect(repo.items.single.name, item.name);
      expect(find.textContaining('Your draft is retained'), findsOneWidget);
      await tap(tester, find.text('Save item'));
      expect(repo.saveOperations[0], repo.saveOperations[1]);
      expect(repo.items.single.name, 'Retained');
    },
  );

  testWidgets(
    'history locks structural edits and reports actual saved goal date',
    (tester) async {
      final item = f.quest();
      repo.items.add(item);
      repo.history = true;
      repo.goal = DailyGoalRevision(
        questId: item.id,
        revision: Revision(2),
        effectiveFrom: DayKey(2026, 1, 16),
        zone: f.zone,
        goal: (item.configuration as QuestConfiguration).dailyGoal,
      );
      await open(tester, item: item);
      expect(find.text('Quest · locked'), findsOneWidget);
      await enter(tester, 'Daily goal', '2');
      await tap(tester, find.text('Save item'));
      expect(find.textContaining('2026-01-16 (Etc/UTC)'), findsOneWidget);
    },
  );

  testWidgets(
    'archive confirmation and active-session guard; archived item can return',
    (tester) async {
      final item = f.quest();
      repo.items.add(item);
      repo.active = true;
      await open(tester, item: item);
      await tester.ensureVisible(find.text('Archive item'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TroveButton>(
              find.widgetWithText(TroveButton, 'Archive item'),
            )
            .onPressed,
        isNull,
      );
      await tap(tester, find.text('Cancel'));
      repo.active = false;
      await tap(tester, find.text('Open'));
      await tap(tester, find.text('Archive item'));
      expect(repo.archived, isEmpty);
      await tap(tester, find.text('Archive item').last);
      expect(repo.items.single.archived, true);
      await tap(tester, find.text('Done'));
      await open(tester, item: repo.items.single);
      await tap(tester, find.text('Save and unarchive'));
      expect(repo.items.single.archived, false);
    },
  );

  testWidgets(
    'groups create, rename, reorder, remove and reassign; item move keeps economics',
    (tester) async {
      repo.groups.addAll([
        f.group(name: 'First'),
        Group(
          id: GroupId(f.uuid(4)),
          revision: Revision(1),
          name: 'Second',
          order: 1,
        ),
      ]);
      repo.items.add(f.quest(groupId: repo.groups.first.id));
      await open(tester, groups: true);
      await tap(tester, find.byTooltip('Move Second earlier'));
      expect(repo.groups.firstWhere((g) => g.name == 'Second').order, 0);
      await tap(tester, find.text('New group'));
      await tester.enterText(find.byType(TextFormField), 'New');
      await tap(tester, find.text('Save group'));
      expect(repo.groups.length, 3);
      await tap(tester, find.text('Rename New'));
      await tester.enterText(find.byType(TextFormField), 'Renamed');
      await tap(tester, find.text('Save group'));
      expect(repo.groups.any((g) => g.name == 'Renamed'), true);
      await tap(tester, find.text('Configure Synthetic Quest'));
      await choose(tester, 'Group', 'Renamed');
      final config = repo.items.single.configuration as QuestConfiguration;
      await tap(tester, find.text('Save item'));
      await tap(tester, find.text('Done'));
      final renamed = repo.groups.firstWhere((g) => g.name == 'Renamed');
      expect(repo.items.single.groupId, renamed.id);
      expect(
        (repo.items.single.configuration as QuestConfiguration)
            .ratesPerHour
            .coins,
        config.ratesPerHour.coins,
      );
      await tap(tester, find.text('Remove Renamed'));
      expect(repo.items.single.groupId, renamed.id);
      await tap(tester, find.text('Remove group'));
      expect(repo.items.single.groupId, isNull);
      expect(repo.groups.length, 2);
    },
  );

  testWidgets('in-flight save cannot be duplicated or dismissed', (
    tester,
  ) async {
    final item = f.quest();
    repo.items.add(item);
    repo.pending = Completer<Result<Item>>();
    await open(tester, item: item);
    await tester.ensureVisible(find.text('Save item'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save item'));
    await tester.pump();
    expect(repo.saveOperations.length, 1);
    await tester.tap(find.text('Saving…'), warnIfMissed: false);
    await tester.pump();
    expect(repo.saveOperations.length, 1);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(ItemEditor), findsOneWidget);
    repo.pending!.complete(Success(item));
    await tester.pumpAndSettle();
    expect(find.text('Item saved'), findsOneWidget);
  });

  testWidgets('stale edit retains draft and explicit reload discards it', (
    tester,
  ) async {
    final item = f.quest();
    repo.items.add(item);
    repo.failNext = const StaleRevision();
    await open(tester, item: item);
    await enter(tester, 'Item name', 'Stale draft');
    await tap(tester, find.text('Save item'));
    expect(repo.items.single.name, item.name);
    expect(find.text('Stale draft'), findsOneWidget);
    await tap(tester, find.text('Discard draft and reload'));
    expect(find.text(item.name), findsOneWidget);
    expect(find.text('Stale draft'), findsNothing);
  });

  testWidgets(
    'a history race refuses structural changes and offers a fresh item',
    (tester) async {
      final item = f.award();
      repo.items.add(item);
      await open(tester, item: item);
      repo.history = true;
      await tap(tester, find.text('Grant spending budget'));
      await tap(tester, find.text('Save item'));
      expect(
        (repo.items.single.configuration as AwardConfiguration).budgetGrant,
        isNotNull,
      );
      await tap(tester, find.text('Create another item'));
      expect(find.text('Create item'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(repo.items.single.id, item.id);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets('layout controls fit ${scale}x and reorder items', (
      tester,
    ) async {
      tester.view.physicalSize = Size(
        scale == 1 ? 390 : 320,
        scale == 1 ? 844 : 568,
      );
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      repo.items.addAll([f.quest(), f.award()]);
      final boundary = GlobalKey();
      await open(tester, groups: true, boundary: boundary);
      await capture(tester, boundary, 'groups-${scale}x');
      await tap(
        tester,
        find.byTooltip('Move Synthetic Combined Award earlier'),
      );
      expect(repo.items.firstWhere((i) => i.type == ItemType.award).order, 0);
      expect(repo.items.firstWhere((i) => i.type == ItemType.quest).order, 1);
      expect(tester.takeException(), isNull);
    });
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('configuration fits ${scale}x phone, keyboard and semantics', (
      tester,
    ) async {
      tester.view.physicalSize = Size(
        scale == 1 ? 390 : 320,
        scale == 1 ? 844 : 568,
      );
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final boundary = GlobalKey();
      await open(tester, item: f.quest(), boundary: boundary);
      final semantics = tester.ensureSemantics();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      semantics.dispose();
      await capture(tester, boundary, 'configuration-${scale}x');
      await enter(tester, 'Item name', 'Keyboard draft');
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save item'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.text('Save item')).bottom,
        lessThan(tester.view.physicalSize.height - 220),
      );
      await capture(tester, boundary, 'configuration-keyboard-${scale}x');
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Keyboard draft'));
      await tester.pumpAndSettle();
      expect(find.text('Keyboard draft'), findsOneWidget);
      await tap(tester, find.text('Cancel'));
      expect(repo.items, isEmpty);
    });
  }
}

Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('UI_EVIDENCE')) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory('build/ui-evidence').createSync(recursive: true);
    File('build/ui-evidence/$name.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
