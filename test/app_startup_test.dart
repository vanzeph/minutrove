import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app_startup.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/home/home.dart';
import 'package:minutrove/features/items/items.dart';
import 'package:minutrove/platform/audio/completion_chime.dart';
import 'package:minutrove/platform/notifications/notification_taps.dart';
import 'package:minutrove/ui/core/core.dart' show TroveButton, TroveDialog;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'features/home_shell_test.dart' show flush, launcher, settle;
import 'support/session_fixtures.dart';

/// Scheduler fake with delivery ownership, so composition-level tests can
/// simulate exactly what each platform adapter reports.
final class FakeDeliveryScheduler
    implements NotificationScheduler, CompletionDeliveryOwner {
  FakeDeliveryScheduler([this.status = NotificationPermission.granted]);

  NotificationPermission status;
  final reconciles = <List<NotificationIntent>>[];
  Set<CompletionId> delivered = {};
  final _taps = StreamController<NotificationTap>.broadcast();

  @override
  Future<NotificationPermission> permission() async => status;

  @override
  Future<NotificationPermission> requestPermission({
    required OperationId operationId,
  }) async => status;

  @override
  Future<Result<NotificationPermission>> reconcile({
    required OperationId operationId,
    required List<NotificationIntent> intents,
  }) async {
    reconciles.add(List.of(intents));
    return Success(status);
  }

  @override
  Future<Result<bool>> openSystemSettings({
    required OperationId operationId,
  }) async => const Success<bool>(true);

  @override
  bool ownsDelivery(CompletionId completionId) =>
      delivered.contains(completionId);

  @override
  Stream<NotificationTap> get taps => _taps.stream;

  /// Simulates one deduplicated OS tap.
  void emitTap(CompletionId completionId) =>
      _taps.add(NotificationTap(completionId: completionId));
}

/// Opens the real composition over an isolated ffi database. The clock and
/// scheduler are deterministic so a journey earns and settles exactly.
class StartupFixture {
  final clock = SessionClock();
  final scheduler = FakeDeliveryScheduler();
  final chimeChannel = const MethodChannel(CompletionChime.channelName);
  final chimeRequests = <String>[];
  late Directory directory;
  AppComposition? composition;

  String get databasePath => '${directory.path}/minutrove.db';

  Future<void> create() async {
    directory = await Directory.systemTemp.createTemp('minutrove-startup-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(chimeChannel, (call) async {
          final arguments = call.arguments;
          if (arguments is Map) {
            chimeRequests.add(arguments['completionId'] as String);
          }
          return 'suppressed';
        });
  }

  Future<void> destroy() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(chimeChannel, null);
    await directory.delete(recursive: true);
  }

  Future<Result<(AppComposition, bool firstRun)>> open() async {
    final firstRun = !File(databasePath).existsSync();
    final result = await AppComposition.open(
      databasePath: databasePath,
      factory: databaseFactoryFfi,
      calendar: IanaReportingCalendar(),
      clock: clock,
      scheduler: scheduler,
      chime: CompletionChime(channel: chimeChannel),
      diagnosticsFile: File('${directory.path}/recovery.log'),
      readDeviceZone: () async => ReportingZone('Etc/UTC'),
    );
    if (result is Success<AppComposition>) composition = result.value;
    return switch (result) {
      Success<AppComposition>(:final value) => Success((value, firstRun)),
      Failure<AppComposition>(:final error) => Failure(error),
    };
  }

  Future<T> read<T>(Future<T> Function(StoreReader) query) async {
    final composition = this.composition!;
    final result = await composition.store.read(query);
    return switch (result) {
      Success<T>(:final value) => value,
      Failure<T>(:final error) => throw error,
    };
  }
}

Future<void> pumpApp(WidgetTester tester, StartupFixture fixture) async {
  await tester.pumpWidget(MinutroveStartup(open: fixture.open));
  for (var attempt = 0; attempt < 100; attempt++) {
    await flush(tester);
    // Ready means the shell or onboarding rendered over the opened store.
    if (fixture.composition != null &&
        (find.text('Minutrove').evaluate().isNotEmpty ||
            find.text('Turn your time into treasure').evaluate().isNotEmpty)) {
      return;
    }
  }
  fail('The startup composition did not become ready');
}

Future<void> awaitFinder(
  WidgetTester tester,
  Finder finder,
  String reason,
) async {
  for (var attempt = 0; attempt < 100 && finder.evaluate().isEmpty; attempt++) {
    await flush(tester);
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder.evaluate(), isNotEmpty, reason: reason);
}

Future<void> tapText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await awaitFinder(tester, finder, 'The "$text" action is available');
  await tester.ensureVisible(finder.last);
  await settle(tester);
  await tester.tap(find.text(text).last);
  await settle(tester);
}

Future<void> enter(WidgetTester tester, String label, String text) async {
  final field = find.descendant(
    of: find.byKey(ValueKey(label)),
    matching: find.byType(TextFormField),
  );
  await awaitFinder(tester, field, 'The $label field is available');
  await tester.ensureVisible(field);
  await settle(tester);
  await tester.enterText(field, text);
  await tester.pump();
}

Future<void> choose(WidgetTester tester, String label, String option) async {
  final button = find.byTooltip(label);
  await tester.ensureVisible(button);
  await settle(tester);
  await tester.tap(button);
  await settle(tester);
  await tester.ensureVisible(find.text(option).last);
  await tester.tap(find.text(option).last);
  await settle(tester);
}

/// Creates a Quest through the real centered editor: a ten-minute session
/// earning 30 Coins and 1 Gem per active minute.
Future<void> createQuest(WidgetTester tester) async {
  await tapText(tester, 'Add your first item');
  await awaitFinder(
    tester,
    find.byKey(const ValueKey('Item name')),
    'The item editor opened',
  );
  await enter(tester, 'Item name', 'Focus');
  await enter(tester, 'Session countdown', '10');
  await enter(tester, 'Coins earned', '30');
  await enter(tester, 'Gems earned', '1');
  await tapText(tester, 'Save item');
  await settle(tester);
  await tapText(tester, 'Done');
}

/// Creates a combined time-and-budget Award through the real editor: one pack
/// costs one Coin and grants five minutes plus ten dollars.
Future<void> createAward(WidgetTester tester) async {
  await awaitFinder(
    tester,
    find.byTooltip('Add item'),
    'The app-bar add action is available',
  );
  await tester.ensureVisible(find.byTooltip('Add item'));
  await settle(tester);
  await tester.tap(find.byTooltip('Add item').first);
  await awaitFinder(
    tester,
    find.byKey(const ValueKey('Item name')),
    'The item editor opened',
  );
  await choose(tester, 'Type', 'Award');
  await enter(tester, 'Item name', 'Gaming');
  await enter(tester, 'Purchase pack name', 'Evening');
  await enter(tester, 'Time per pack', '5');
  await tapText(tester, 'Grant spending budget');
  await enter(tester, 'Budget currency', 'USD');
  await enter(tester, 'Budget per pack', '10');
  await enter(tester, 'Pack price · Coins', '1');
  await tapText(tester, 'Save item');
  await settle(tester);
  await tapText(tester, 'Done');
}

/// Taps a Home tile and waits for its real outcome: a session screen for a
/// Quest or single-dimension Award, or the use-choice dialog for a combined
/// Award. The route future stays pending while the screen is open, so the
/// wait cannot use the tile's enablement as its signal.
Future<void> launchItem(WidgetTester tester, String name) async {
  final tile = launcher(name);
  await awaitFinder(tester, tile, 'The $name tile is on Home');
  await tester.ensureVisible(tile);
  await settle(tester);
  await tester.tap(tile);
  await waitUntil(
    tester,
    () =>
        find.text('Quest session').evaluate().isNotEmpty ||
        find.text('Reward session').evaluate().isNotEmpty ||
        find.byType(TroveDialog).evaluate().isNotEmpty,
    'Tapping $name opens its session or use dialog',
  );
}

/// Session actions recover and re-read before commanding; on a slow host the
/// button can still be disabled right after opening the screen. Wait for an
/// enabled button, exactly like the native integration suite does.
Future<void> tapWhenEnabled(WidgetTester tester, String label) async {
  await waitUntil(
    tester,
    () => tester
        .widgetList<TroveButton>(find.widgetWithText(TroveButton, label))
        .any((button) => button.onPressed != null),
    'The "$label" action is enabled',
  );
  await tapText(tester, label);
}

Future<void> waitUntil(
  WidgetTester tester,
  bool Function() ready,
  String reason,
) async {
  for (var attempt = 0; attempt < 240 && !ready(); attempt++) {
    await flush(tester);
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue, reason: reason);
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

  late StartupFixture fixture;
  setUp(() async {
    fixture = StartupFixture();
    await fixture.create();
  });
  tearDown(() async {
    await fixture.destroy();
  });

  testWidgets(
    'first run onboards once, then the full loop survives a restart',
    (tester) async {
      await pumpApp(tester, fixture);
      await settle(tester);
      // First run: onboarding over the real settings repository.
      expect(find.text('Turn your time into treasure'), findsOneWidget);
      await tapText(tester, 'Get started');
      await settle(tester);
      expect(find.text('Etc/UTC'), findsOneWidget);
      await tapText(tester, 'Continue');
      await settle(tester);
      await tapText(tester, 'Done');
      await settle(tester);
      expect(find.text('Make time for what matters.'), findsOneWidget);
      expect(find.text('0 Coins'), findsOneWidget);

      // Create → earn → early end.
      await createQuest(tester);
      await settle(tester);
      await launchItem(tester, 'Focus');
      await settle(tester);
      expect(find.text('Quest session'), findsOneWidget);
      fixture.clock.advance(4000);
      await settle(tester);
      await tapWhenEnabled(tester, 'End & keep earnings');
      await waitUntil(
        tester,
        () => find.text('Quest session').evaluate().isEmpty,
        'Ending early returns Home with the saved result',
      );
      await tapText(tester, 'Dismiss session result');
      // 30 Coins per minute across four seconds earns exactly two Coins.
      final wallet = (await tester.runAsync<WalletProjection>(
        () => fixture.read((r) => r.wallet()),
      ))!;
      expect(wallet.balances.coins.units, 2000000);
      expect(wallet.balances.gems.units, 66666);
      expect(
        fixture.chimeRequests,
        isEmpty,
        reason: 'An early end never plays the completion cue',
      );

      // Redeem one pack of the combined Award.
      await createAward(tester);
      await settle(tester);
      await tapText(tester, 'Shop');
      await settle(tester);
      await tapText(tester, 'Redeem Gaming');
      await settle(tester);
      await tapText(tester, 'Redeem 1 pack');
      await settle(tester);
      final redeemed = (await tester.runAsync<WalletProjection>(
        () => fixture.read((r) => r.wallet()),
      ))!;
      expect(redeemed.balances.coins.units, 1000000);

      // Partially consume both allowance dimensions.
      await tapText(tester, 'Home');
      await settle(tester);
      await launchItem(tester, 'Gaming');
      await tapText(tester, 'Use time');
      await settle(tester);
      fixture.clock.advance(3000);
      await settle(tester);
      await tapWhenEnabled(tester, 'End & keep remaining time');
      await waitUntil(
        tester,
        () => find.text('Reward session').evaluate().isEmpty,
        'Ending the Award run returns Home',
      );
      await tapText(tester, 'Dismiss session result');
      await settle(tester);
      await launchItem(tester, 'Gaming');
      await tapText(tester, 'Record expense');
      await settle(tester);
      await tester.enterText(find.byType(TextFormField).first, '4');
      await tester.pump();
      await tapText(tester, 'Record USD 4.00');
      await tapText(tester, 'Done');
      await settle(tester);
      final award = (await tester.runAsync<AwardBalance>(
        () => fixture.read((r) async => (await r.awards()).single),
      ))!;
      // Five minutes minus three seconds used, ten dollars minus four spent.
      expect(award.time!.value, 297000);
      expect(award.budget!.minorUnits, 600);

      // Stats reads the same committed history. Dismiss any keyboard left by
      // the expense dialog so the bottom navigation stays hittable.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tapText(tester, 'Stats');
      await settle(tester);
      await awaitFinder(
        tester,
        find.text('Your progress'),
        'The Stats screen opened',
      );

      // Restart: the same file reopens with existing data, exactly once.
      final before = (await tester.runAsync<int>(
        () =>
            fixture.read((r) async => (await r.wallet()).balances.coins.units),
      ))!;
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
      await pumpApp(tester, fixture);
      await settle(tester);
      // Existing database: no second onboarding, and tiles are still present.
      expect(find.text('Turn your time into treasure'), findsNothing);
      expect(find.text('Focus'), findsOneWidget);
      expect(find.text('Gaming'), findsOneWidget);
      final after = (await tester.runAsync<int>(
        () =>
            fixture.read((r) async => (await r.wallet()).balances.coins.units),
      ))!;
      expect(after, before);
    },
  );

  testWidgets('startup failure is actionable and retry opens the app', (
    tester,
  ) async {
    var failures = 0;
    Future<Result<(AppComposition, bool firstRun)>> open() async {
      if (failures++ == 0) {
        return const Failure(StorageUnavailable(retryable: true));
      }
      return fixture.open();
    }

    await tester.pumpWidget(MinutroveStartup(open: open));
    await settle(tester);
    expect(find.text('Minutrove could not open your data'), findsOneWidget);
    await tapText(tester, 'Try again');
    await pumpApp(tester, fixture);
    expect(find.text('Turn your time into treasure'), findsOneWidget);
  });

  testWidgets('notification taps route Home from any tab', (tester) async {
    await pumpApp(tester, fixture);
    await settle(tester);
    await tapText(tester, 'Skip setup');
    await settle(tester);
    await tapText(tester, 'Shop');
    await settle(tester);
    expect(find.text('Reward Shop'), findsOneWidget);
    fixture.scheduler.emitTap(
      CompletionId('00000000-0000-4000-8000-00000000000a'),
    );
    await settle(tester);
    // Home was selected again; the empty state is only visible on Home.
    expect(find.text('Make time for what matters.'), findsOneWidget);
  });

  testWidgets('every committed session mutation reconciles OS notifications', (
    tester,
  ) async {
    await pumpApp(tester, fixture);
    await settle(tester);
    await tapText(tester, 'Skip setup');
    await settle(tester);
    final composition = fixture.composition!;
    final quest = (await tester.runAsync<Item>(() async {
      final result = await composition.items.saveItem(
        operationId: OperationId(randomUuid()),
        item: configuredQuest(seconds: 600),
        expectedRevision: null,
      );
      return (result as Success<Item>).value;
    }))!;
    final started = (await tester.runAsync<Result<SessionMutation>>(
      () => composition.sessions.startSession(
        operationId: OperationId(randomUuid()),
        itemId: quest.id,
        expectedItemRevision: quest.revision,
        conflictChoice: SessionConflictChoice.cancel,
      ),
    ))!;
    expect(started, isA<Success<SessionMutation>>());
    await waitUntil(
      tester,
      () => fixture.scheduler.reconciles.any(
        (intents) => intents.any((intent) => intent.deadlineUtc != null),
      ),
      'Starting scheduled the live deadline notification',
    );
    final paused = (await tester.runAsync<Result<SessionMutation>>(
      () => composition.sessions.pauseSession(
        operationId: OperationId(randomUuid()),
        sessionId: (started as Success<SessionMutation>).value.session.id,
        expectedRevision: started.value.session.revision,
      ),
    ))!;
    expect(paused, isA<Success<SessionMutation>>());
    await waitUntil(
      tester,
      () =>
          fixture.scheduler.reconciles.isNotEmpty &&
          fixture.scheduler.reconciles.last.every(
            (intent) => intent.deadlineUtc == null,
          ),
      'Pausing canceled the deadline notification',
    );
    final ended = (await tester.runAsync<Result<SessionMutation>>(
      () => composition.sessions.endSession(
        operationId: OperationId(randomUuid()),
        sessionId: (started as Success<SessionMutation>).value.session.id,
        expectedRevision:
            (paused as Success<SessionMutation>).value.session.revision,
      ),
    ))!;
    expect(ended, isA<Success<SessionMutation>>());
    await waitUntil(
      tester,
      () =>
          fixture.chimeRequests.isEmpty &&
          fixture.scheduler.reconciles.isNotEmpty,
      'The ended session synced its notification state',
    );
    final intents = (await tester.runAsync<List<NotificationIntent>>(
      () => fixture.read((r) => r.notificationIntents()),
    ))!;
    expect(
      intents.single.completionChimeHandled,
      isTrue,
      reason: 'An ended session consumes its cue without playing sound',
    );
  });

  test('restore rebuilds the graph over the reopened database', () async {
    final open = await fixture.open();
    expect(open, isA<Success<(AppComposition, bool)>>());
    final composition = (open as Success<(AppComposition, bool)>).value.$1;
    await composition.start();
    final created = await composition.items.saveItem(
      operationId: OperationId('00000000-0000-4000-8000-0000000000a1'),
      item: configuredQuest(seconds: 60),
      expectedRevision: null,
    );
    expect(created, isA<Success<Item>>());
    final oldStore = composition.store;
    // Export, restore the same file through the real swap path, then rebuild
    // exactly as the Settings onRestored callback does.
    final export = await composition.backup.exportBackup(
      operationId: OperationId('00000000-0000-4000-8000-0000000000a2'),
    );
    final file = (export as Success<BackupFile>).value;
    final inspection = await composition.backup.inspectBackup(file);
    final settings = await composition.settings.getSettings();
    final restored = await composition.backup.restoreBackup(
      operationId: OperationId('00000000-0000-4000-8000-0000000000a3'),
      file: file,
      confirmation: RestoreConfirmation(
        preview: (inspection as Success<BackupPreview>).value,
        expectedSettingsRevision:
            (settings as Success<AppSettings>).value.revision,
      ),
    );
    expect(restored, isA<Success<RestoreReceipt>>());
    final rebuilt = await composition.rebuild();
    expect(identical(rebuilt.store, oldStore), isFalse);
    expect(identical(rebuilt.scheduler, composition.scheduler), isTrue);
    final home = await watchSqliteHome(rebuilt.store).first;
    expect(home.items, hasLength(1));
    expect(home.items.single.name, (created as Success<Item>).value.name);
    await rebuilt.close();
    fixture.composition = null;
  });
}
