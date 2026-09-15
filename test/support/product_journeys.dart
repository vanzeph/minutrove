import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app_startup.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/home/home_shell.dart'
    show CompactSessionSlot;
import 'package:minutrove/features/stats/stats_chart.dart';
import 'package:minutrove/platform/audio/completion_chime.dart';
import 'package:minutrove/ui/core/core.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import '../app_startup_test.dart'
    show
        FakeDeliveryScheduler,
        awaitFinder,
        launchItem,
        tapText,
        tapWhenEnabled,
        waitUntil;
import '../data/support.dart' as f;
import '../features/home_shell_test.dart' show flush, launcher, settle;
import 'session_fixtures.dart';

/// Deterministic full-product acceptance journeys shared by two runners:
/// the widget-level suite over an isolated ffi database and the native
/// integration suite over the real on-device SQLite plugin. The clock and
/// notification scheduler are fixtures so earnings, deadlines and reporting
/// dates settle exactly; the store, transactions, projections, restarts and
/// every screen under test are the real product.
class JourneyFixture {
  JourneyFixture({required this.factory, required this.chime});

  /// The real on-device plugin factory in the integration runner; ffi locally.
  final sqflite.DatabaseFactory factory;
  final CompletionChime chime;
  final clock = SessionClock();
  final scheduler = FakeDeliveryScheduler();
  late Directory directory;
  AppComposition? composition;
  var _serial = 900;

  OperationId operation() => OperationId(f.uuid(_serial++));
  String get databasePath => '${directory.path}/minutrove.db';

  Future<void> create() async {
    directory = await Directory.systemTemp.createTemp('minutrove-journeys-');
  }

  Future<void> destroy() async {
    // Teardown cannot pump, so fake-zone tail work must never be awaited
    // here; like the shared startup fixture, deleting the open ffi database
    // file is safe and the process ends with the suite. Journeys close
    // their composition inside the test body when they need a clean file.
    composition = null;
    await directory.delete(recursive: true);
  }

  Future<Result<(AppComposition, bool firstRun)>> open() async {
    final firstRun = !File(databasePath).existsSync();
    final result = await AppComposition.open(
      databasePath: databasePath,
      factory: factory,
      calendar: IanaReportingCalendar(),
      clock: clock,
      scheduler: scheduler,
      chime: chime,
      diagnosticsFile: File('${directory.path}/recovery.log'),
      readDeviceZone: () async => ReportingZone('Etc/UTC'),
    );
    if (result is Success<AppComposition>) composition = result.value;
    return switch (result) {
      Success<AppComposition>(:final value) => Success((value, firstRun)),
      Failure<AppComposition>(:final error) => Failure(error),
    };
  }
}

var useCounter = 0;

/// Real repository and store work: in the widget runner the ffi database
/// answers on a background isolate, and widget commands complete through
/// fake-zone microtask cascades. Awaiting either inside one runAsync call
/// deadlocks, so the action starts in the real zone and the caller then
/// alternates real event-loop time with fake microtask flushes — the same
/// interleaving the shared flush helper uses — until the action completes.
/// In the native runner this is ordinary awaited async work.
Future<T> use<T>(
  WidgetTester tester,
  JourneyFixture fixture,
  Future<T> Function(AppComposition composition) action,
) async {
  final completer = Completer<T>();
  await tester.runAsync<Object?>(() async {
    action(fixture.composition!).then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    return null;
  });
  useCounter++;
  final useIndex = useCounter;
  for (var attempt = 0; !completer.isCompleted; attempt++) {
    if (attempt >= 1200) {
      fail(
        'The journey action #$useIndex did not complete within its bounded wait',
      );
    }
    await tester.runAsync<Object?>(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  // Command completion is not stream completion: keep alternating so the
  // watch cascades every commit triggers always reach the widgets.
  for (var i = 0; i < 8; i++) {
    await tester.runAsync<Object?>(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  return completer.future;
}

Future<T> readStore<T>(
  WidgetTester tester,
  JourneyFixture fixture,
  Future<T> Function(StoreReader records) query,
) => use(
  tester,
  fixture,
  (composition) async => f.success(await composition.store.read(query)),
);

Future<void> pumpJourneyApp(WidgetTester tester, JourneyFixture fixture) async {
  await tester.pumpWidget(MinutroveStartup(open: fixture.open));
  for (var attempt = 0; attempt < 100; attempt++) {
    await flush(tester);
    if (fixture.composition != null &&
        (find.text('Minutrove').evaluate().isNotEmpty ||
            find.text('Turn your time into treasure').evaluate().isNotEmpty)) {
      return;
    }
  }
  fail('The journey composition did not become ready');
}

Future<void> skipOnboarding(WidgetTester tester) async {
  await awaitFinder(
    tester,
    find.text('Turn your time into treasure'),
    'A fresh journey database opens onboarding',
  );
  await tapText(tester, 'Skip setup');
  await settle(tester);
}

/// Unmount the app so periodic timers (Stats day refresh, lifecycle
/// checkpoints) are disposed, then drain the unmounted root's unawaited
/// close and the final stream cascades while the body can still pump. A
/// pending fake-zone link left for teardown cannot complete there.
Future<void> endJourney(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  for (var i = 0; i < 8; i++) {
    await tester.runAsync<Object?>(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
}

/// Reveal an item inside a lazily built list. Slivers only build children
/// within the viewport plus cache extent, so below-the-fold Shop offers and
/// Stats charts must be scrolled into existence before finders can see them.
Future<void> revealInList(
  WidgetTester tester,
  Finder finder,
  Key scrollableKey,
) async {
  if (finder.evaluate().isNotEmpty) return;
  final view = find.byKey(scrollableKey);
  try {
    await tester.dragUntilVisible(
      finder,
      view,
      const Offset(0, -300),
      maxIteration: 20,
    );
  } on StateError {
    // The item may live above the current position after earlier scrolling.
    await tester.dragUntilVisible(
      finder,
      view,
      const Offset(0, 300),
      maxIteration: 40,
    );
  }
  await settle(tester);
}

/// The filters dialog's item chooser is its own lazily built list; reveal
/// and tap the labeled row inside the dialog.
Future<void> chooseFilterRow(WidgetTester tester, String label) async {
  await awaitFinder(
    tester,
    find.text('Choose items'),
    'The item chooser list opened',
  );
  final target = find.text(label);
  if (target.evaluate().isEmpty) {
    await tester.dragUntilVisible(
      target,
      find
          .descendant(
            of: find.byType(Dialog),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .first,
      const Offset(0, -300),
      maxIteration: 20,
    );
    await settle(tester);
  }
  await tester.ensureVisible(target.last);
  await settle(tester);
  await tester.tap(target.last);
  await settle(tester);
}

Future<void> revealOffer(WidgetTester tester, String label) => revealInList(
  tester,
  find.text(label),
  const PageStorageKey<String>('shop-scroll'),
);

Future<void> revealChart(WidgetTester tester, Finder finder) =>
    revealInList(tester, finder, const PageStorageKey<String>('stats-scroll'));

/// Wait for a named tile with a poll-safe finder; the shared launcher
/// helper's `.first` must only be evaluated once the tile exists.
Future<void> waitForTile(WidgetTester tester, String name) => waitUntil(
  tester,
  () => find
      .byWidgetPredicate((widget) => widget is ItemTile && widget.name == name)
      .evaluate()
      .isNotEmpty,
  'The $name tile is on Home',
);

/// Launch a visible tile through the shared tap helper.
Future<void> launchByName(WidgetTester tester, String name) async {
  await waitForTile(tester, name);
  await launchItem(tester, name);
}

/// Single-tap a Home tile and let the deferred recognizer fire, without
/// asserting which route the tap opens.
Future<void> tapTile(WidgetTester tester, String name) async {
  await waitForTile(tester, name);
  final tile = launcher(name);
  await tester.ensureVisible(tile);
  await settle(tester);
  await tester.tap(tile);
  await settle(tester);
}

/// Move the deterministic clock to another civil day, keeping the monotonic
/// anchor strictly increasing as every boot sample must be.
void atDay(JourneyFixture fixture, DateTime day) {
  fixture.clock.utc = DateTime.utc(day.year, day.month, day.day, 12);
  fixture.clock.monotonic += 86400000;
}

Item journeyQuest({
  required ItemId id,
  required String name,
  int durationSeconds = 600,
  int coinsPerHour = 120000000,
  int gemsPerHour = 0,
  String iconKey = 'gamepad',
  int colorArgb = 0xff883366,
  int revision = 1,
}) => Item(
  id: id,
  revision: Revision(revision),
  name: name,
  iconKey: iconKey,
  colorArgb: colorArgb,
  groupId: null,
  order: 0,
  archived: false,
  configuration: QuestConfiguration(
    duration: Milliseconds.seconds(durationSeconds),
    ratesPerHour: CurrencyAmounts(
      coins: MicroAmount(coinsPerHour),
      gems: MicroAmount(gemsPerHour),
    ),
  ),
);

Item journeyAward({
  required ItemId id,
  required String name,
  required int priceCoins,
  int? timeGrantSeconds,
  int? budgetMinorUnits,
  String iconKey = 'gamepad',
  int colorArgb = 0xff883366,
  int revision = 1,
}) => Item(
  id: id,
  revision: Revision(revision),
  name: name,
  iconKey: iconKey,
  colorArgb: colorArgb,
  groupId: null,
  order: 0,
  archived: false,
  configuration: AwardConfiguration(
    packName: 'Pack',
    price: CurrencyAmounts(
      coins: MicroAmount(priceCoins),
      gems: MicroAmount(0),
    ),
    timeGrant: timeGrantSeconds == null
        ? null
        : Milliseconds.seconds(timeGrantSeconds),
    budgetGrant: budgetMinorUnits == null
        ? null
        : BudgetAmount(
            BudgetCurrency.fromMetadata('USD', f.metadata),
            budgetMinorUnits,
          ),
  ),
);

Future<Item> createItem(
  WidgetTester tester,
  JourneyFixture fixture,
  Item item,
) => use(tester, fixture, (composition) async {
  return f.success(
    await composition.items.saveItem(
      operationId: fixture.operation(),
      item: item,
      expectedRevision: null,
    ),
  );
});

Future<SessionMutation> startQuestSession(
  WidgetTester tester,
  JourneyFixture fixture,
  Item quest,
) => use(tester, fixture, (composition) async {
  return f.success(
    await composition.sessions.startSession(
      operationId: fixture.operation(),
      itemId: quest.id,
      expectedItemRevision: quest.revision,
      conflictChoice: SessionConflictChoice.cancel,
    ),
  );
});

Future<SessionMutation> endQuestSession(
  WidgetTester tester,
  JourneyFixture fixture,
  SessionMutation started,
) => use(tester, fixture, (composition) async {
  return f.success(
    await composition.sessions.endSession(
      operationId: fixture.operation(),
      sessionId: started.session.id,
      expectedRevision: started.session.revision,
    ),
  );
});

/// One repository-driven quest run of exactly [activeMilliseconds]; each
/// journey asserts the resulting stored amounts against analytic values.
Future<SessionMutation> runQuest(
  WidgetTester tester,
  JourneyFixture fixture,
  Item quest,
  int activeMilliseconds,
) async {
  final started = await startQuestSession(tester, fixture, quest);
  await settle(tester);
  await waitUntil(
    tester,
    () => find.byType(CompactSessionSlot).evaluate().isNotEmpty,
    'The started run occupies the session slot on Home',
  );
  fixture.clock.advance(activeMilliseconds);
  return endQuestSession(tester, fixture, started);
}

Future<EconomicState> redeem(
  WidgetTester tester,
  JourneyFixture fixture,
  Item award,
  int quantity, {
  OperationId? operation,
}) => use(tester, fixture, (composition) async {
  return f.success(
    await composition.economy.redeemAward(
      operationId: operation ?? fixture.operation(),
      awardId: award.id,
      expectedRevision: award.revision,
      quantity: PurchaseQuantity(quantity),
    ),
  );
});

Future<WalletProjection> readWallet(
  WidgetTester tester,
  JourneyFixture fixture,
) => readStore(tester, fixture, (records) => records.wallet());

Future<List<String>> readMismatches(
  WidgetTester tester,
  JourneyFixture fixture,
) => readStore(tester, fixture, (records) => records.projectionMismatches());

/// Retract any software keyboard raised by text entry. On a real device the
/// OS keyboard overlays the centered dialog and swallows taps aimed at the
/// actions beneath it, so every entry helper closes it before the journey
/// continues. (The Android emulator images run with a hardware keyboard, so
/// only the iOS simulator actually raises one; unfocusing is harmless in
/// every runner.)
Future<void> dismissKeyboard(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await settle(tester);
}

Future<void> enterQuantity(WidgetTester tester, String text) async {
  final field = find.byKey(const ValueKey('purchase-quantity'));
  await awaitFinder(tester, field, 'The purchase quantity field is available');
  await tester.enterText(field, text);
  await tester.pump();
  await dismissKeyboard(tester);
}

Future<void> enterExpenseAmount(WidgetTester tester, String text) async {
  final field = find.descendant(
    of: find.widgetWithText(TroveTextField, 'Actual cost · USD'),
    matching: find.byType(TextFormField),
  );
  await awaitFinder(tester, field, 'The expense amount field is available');
  await tester.enterText(field, text);
  await tester.pump();
  await dismissKeyboard(tester);
}

/// Wait for the Home receipt of an ended session and dismiss it. Waiting on
/// the button with the full bounded budget (rather than tapText's shorter
/// awaitFinder) covers the native runners' slower watch cascades, and
/// dismissing each receipt eagerly means a later receipt assertion can never
/// be satisfied by a stale earlier one.
Future<void> dismissSessionResult(WidgetTester tester) async {
  await waitUntil(
    tester,
    () => find.text('Dismiss session result').evaluate().isNotEmpty,
    'An ended session posts its Home receipt',
  );
  await tapText(tester, 'Dismiss session result');
}

int chartTotal(WidgetTester tester, StatsPeriod period) {
  final chart = tester.widget<StatsChart>(
    find.byWidgetPredicate(
      (widget) => widget is StatsChart && widget.period == period,
    ),
  );
  return chart.buckets.fold(0, (total, bucket) => total + bucket.value);
}

Future<List<LedgerEntry>> readLedger(
  WidgetTester tester,
  JourneyFixture fixture,
) => readStore(tester, fixture, (records) => records.ledger());

int sumWindow(
  List<LedgerEntry> entries,
  bool Function(LedgerEntry) dimension,
  DateTime start,
  DateTime end, {
  ItemId? item,
}) => entries
    .where(dimension)
    .where(
      (entry) =>
          (item == null || entry.itemId == item) &&
          !entry.timestamp.utc.isBefore(start) &&
          entry.timestamp.utc.isBefore(end),
    )
    .fold(0, (total, entry) => total + entry.delta.abs());

bool isQuestTime(LedgerEntry entry) =>
    entry.dimension is TimeDimension && entry.delta > 0;

bool isCoins(LedgerEntry entry) =>
    entry.dimension is VirtualCurrencyDimension &&
    entry.delta > 0 &&
    (entry.dimension as VirtualCurrencyDimension).currency ==
        VirtualCurrency.coins;

bool isUsdSpent(LedgerEntry entry) =>
    entry.dimension is BudgetDimension && entry.delta < 0;

/// Journey: exact earnings with an early end, pause exclusion, fractional
/// split-session preservation, one completion with one cue, duplicate
/// reconciliation, and a persisted restart without duplicate credit.
///
/// The authoritative example: five active minutes at 2 Coins and 0.04 Gems per
/// minute retain exactly 10 Coins and 0.2 Gems; paused time contributes
/// nothing.
Future<void> journeyEarnPauseSplitCompleteRestart(
  WidgetTester tester,
  JourneyFixture fixture,
) async {
  await pumpJourneyApp(tester, fixture);
  await skipOnboarding(tester);
  const coinsPerHour = 120000000; // 2 Coins per active minute.
  const gemsPerHour = 2400000; // 0.04 Gems per active minute.
  await createItem(
    tester,
    fixture,
    journeyQuest(
      id: ItemId(f.uuid(1)),
      name: 'Precise',
      coinsPerHour: coinsPerHour,
      gemsPerHour: gemsPerHour,
    ),
  );

  // Two active minutes, then pause.
  await launchByName(tester, 'Precise');
  await settle(tester);
  expect(find.text('Quest session'), findsOneWidget);
  fixture.clock.advance(120000);
  await settle(tester);
  await tapWhenEnabled(tester, 'Pause session');
  await waitUntil(
    tester,
    () => find.text('Resume session').evaluate().isNotEmpty,
    'Pausing reveals the resume action',
  );
  final paused = await readStore<Session?>(
    tester,
    fixture,
    (records) => records.activeSession(),
  );
  expect(paused!.status, SessionStatus.paused);
  expect(paused.settled.value, 120000, reason: 'Two active minutes settled');
  var wallet = await readWallet(tester, fixture);
  expect(wallet.balances.coins.units, 4000000, reason: '2 min × 2 Coins/min');
  expect(wallet.balances.gems.units, 80000, reason: '2 min × 0.04 Gems/min');

  // Three paused minutes contribute nothing.
  fixture.clock.advance(180000);
  await use(
    tester,
    fixture,
    (composition) => composition.lifecycle.reconcile(),
  );
  final afterPause = await readStore<Session?>(
    tester,
    fixture,
    (records) => records.activeSession(),
  );
  expect(afterPause!.settled.value, 120000, reason: 'Paused time is excluded');
  wallet = await readWallet(tester, fixture);
  expect(wallet.balances.coins.units, 4000000, reason: 'Pause earns nothing');
  expect(wallet.balances.gems.units, 80000, reason: 'Pause earns nothing');

  // Three more active minutes, then an early end keeps the exact total.
  await tapWhenEnabled(tester, 'Resume session');
  await waitUntil(
    tester,
    () => tester
        .widgetList<TroveButton>(
          find.widgetWithText(TroveButton, 'Pause session'),
        )
        .any((button) => button.onPressed != null),
    'Resuming re-arms the pause action before time advances',
  );
  fixture.clock.advance(180000);
  await settle(tester);
  await tapWhenEnabled(tester, 'End & keep earnings');
  await waitUntil(
    tester,
    () => find.text('Quest session').evaluate().isEmpty,
    'Ending early returns Home with the saved result',
  );
  await dismissSessionResult(tester);
  wallet = await readWallet(tester, fixture);
  expect(
    wallet.balances.coins.units,
    10000000,
    reason: '5 active minutes × 2 Coins/min = exactly 10 Coins',
  );
  expect(
    wallet.balances.gems.units,
    200000,
    reason: '5 active minutes × 0.04 Gems/min = exactly 0.2 Gems',
  );
  final ended = await readStore<Session?>(
    tester,
    fixture,
    (records) => records.session(paused.id),
  );
  expect(ended!.status, SessionStatus.ended);
  expect(ended.settled.value, 300000, reason: 'Only active time settles');
  expect(ended.intervals.map((interval) => interval.active.value), [
    120000,
    180000,
  ], reason: 'The paused gap never became active time');
  final endedLedger = await readStore<List<LedgerEntry>>(
    tester,
    fixture,
    (records) => records.ledger(sessionId: ended.id),
  );
  expect(
    endedLedger
        .where(isQuestTime)
        .fold<int>(0, (total, entry) => total + entry.delta),
    300000,
    reason: 'Ledger time agrees with the settled session',
  );
  expect(
    endedLedger
        .where(
          (entry) =>
              entry.dimension is VirtualCurrencyDimension &&
              (entry.dimension as VirtualCurrencyDimension).currency ==
                  VirtualCurrency.coins,
        )
        .fold<int>(0, (total, entry) => total + entry.delta),
    10000000,
    reason: 'Ledger coins agree with the wallet',
  );
  expect(
    fixture.scheduler.reconciles.isNotEmpty &&
        fixture.scheduler.reconciles.last.every(
          (intent) => intent.deadlineUtc == null,
        ),
    isTrue,
    reason: 'Ending canceled the deadline notification',
  );

  // Split sessions preserve fractional totals: 1.000003 Coins per hour earns
  // floor((rate×t+r)/3.6e6) with the remainder carried, so two separate
  // one-minute runs match one continuous two-minute run exactly.
  final frugal = await createItem(
    tester,
    fixture,
    journeyQuest(id: ItemId(f.uuid(2)), name: 'Frugal', coinsPerHour: 1000003),
  );
  await runQuest(tester, fixture, frugal, 60000);
  await runQuest(tester, fixture, frugal, 60000);
  wallet = await readWallet(tester, fixture);
  expect(
    wallet.balances.coins.units - 10000000,
    33333,
    reason: 'Two split minutes equal one continuous minute pair (33333)',
  );
  final remainder = await readStore<QuestAccrualRemainder?>(
    tester,
    fixture,
    (records) => records.remainder(frugal.id, VirtualCurrency.coins),
  );
  expect(
    remainder!.remainder.value,
    1560000,
    reason: 'The carried remainder equals the single continuous run',
  );

  // Completion at zero settles once, credits exactly, consumes one cue and
  // returns Home; a duplicate callback cannot pay twice.
  final sprint = await createItem(
    tester,
    fixture,
    journeyQuest(
      id: ItemId(f.uuid(3)),
      name: 'Sprint',
      durationSeconds: 10,
      coinsPerHour: 216000000, // 600000 millionths over ten seconds.
      gemsPerHour: 1800000, // 5000 millionths over ten seconds.
    ),
  );
  final started = await startQuestSession(tester, fixture, sprint);
  await waitUntil(
    tester,
    () => find.textContaining('Running ·').evaluate().isNotEmpty,
    'The running session occupies the compact slot on Home',
  );
  fixture.clock.advance(11000); // Past the ten-second deadline.
  final beforeCompletion = await readWallet(tester, fixture);
  final completed = await use(
    tester,
    fixture,
    (composition) => composition.lifecycle.reconcile(),
  );
  final mutation = f.success(completed)!;
  expect(mutation.session.status, SessionStatus.completed);
  expect(mutation.session.settled.value, 10000, reason: 'Capped at the run');
  expect(mutation.session.completionId, started.session.completionId);
  await awaitFinder(
    tester,
    find.text('Time well spent'),
    'The foreground returns Home with the settled result',
  );
  expect(
    find.textContaining('Sprint completed after 10s'),
    findsOneWidget,
    reason: 'The completion receipt states the settled time',
  );
  wallet = await readWallet(tester, fixture);
  expect(
    wallet.balances.coins.units - beforeCompletion.balances.coins.units,
    600000,
    reason: 'Ten seconds at 3.6 Coins/min credited exactly',
  );
  expect(
    wallet.balances.gems.units - beforeCompletion.balances.gems.units,
    5000,
    reason: 'Ten seconds of Gems credited exactly',
  );
  final duplicate = await use(
    tester,
    fixture,
    (composition) => composition.lifecycle.reconcile(),
  );
  expect(f.success(duplicate), isNull, reason: 'Nothing left to reconcile');
  wallet = await readWallet(tester, fixture);
  expect(
    wallet.balances.coins.units - beforeCompletion.balances.coins.units,
    600000,
    reason: 'A duplicate callback pays nothing more',
  );
  await use(tester, fixture, (composition) => composition.sessions.drain());
  final intents = await readStore<List<NotificationIntent>>(
    tester,
    fixture,
    (records) => records.notificationIntents(),
  );
  expect(
    intents
        .where((intent) => intent.completionId == started.session.completionId)
        .single
        .completionChimeHandled,
    isTrue,
    reason: 'The one-shot completion cue is consumed exactly once',
  );
  expect(await readMismatches(tester, fixture), isEmpty);

  // Restart over the same file: state persists and nothing is paid twice.
  final beforeRestart = await readWallet(tester, fixture);
  final historyBefore = await readStore<List<String>>(
    tester,
    fixture,
    (records) async => [
      for (final entry in await records.ledger()) entry.id.value,
    ],
  );
  await tester.pumpWidget(const SizedBox());
  await flush(tester);
  await use(tester, fixture, (composition) => composition.close());
  fixture.composition = null;
  await pumpJourneyApp(tester, fixture);
  await settle(tester);
  expect(
    find.text('Turn your time into treasure'),
    findsNothing,
    reason: 'An existing database never reopens onboarding',
  );
  expect(find.text('Precise'), findsOneWidget);
  var afterRestart = await readWallet(tester, fixture);
  expect(
    afterRestart.balances.coins.units,
    beforeRestart.balances.coins.units,
    reason: 'Persisted balances survive the restart',
  );
  expect(afterRestart.balances.gems.units, beforeRestart.balances.gems.units);
  final activeAfterRestart = await readStore<Session?>(
    tester,
    fixture,
    (records) => records.activeSession(),
  );
  expect(activeAfterRestart, isNull, reason: 'No session was restarted');
  await use(
    tester,
    fixture,
    (composition) => composition.lifecycle.reconcile(),
  );
  afterRestart = await readWallet(tester, fixture);
  expect(
    afterRestart.balances.coins.units,
    beforeRestart.balances.coins.units,
    reason: 'Startup recovery pays nothing twice',
  );
  final historyAfter = await readStore<List<String>>(
    tester,
    fixture,
    (records) async => [
      for (final entry in await records.ledger()) entry.id.value,
    ],
  );
  expect(historyAfter, historyBefore, reason: 'History is unchanged');
  expect(await readMismatches(tester, fixture), isEmpty);
  await endJourney(tester);
}

/// Journey: Quest and Award variants (Coins-only, Gems-only, time-only,
/// budget-only, combined) plus icon and color independence. Appearance edits
/// never change type, earning rules, prices, balances or history.
Future<void> journeyVariantsAndAppearanceIndependence(
  WidgetTester tester,
  JourneyFixture fixture,
) async {
  await pumpJourneyApp(tester, fixture);
  await skipOnboarding(tester);
  final coinQuest = await createItem(
    tester,
    fixture,
    journeyQuest(
      id: ItemId(f.uuid(1)),
      name: 'Coin Quest',
      coinsPerHour: 120000000,
    ),
  );
  final gemQuest = await createItem(
    tester,
    fixture,
    journeyQuest(
      id: ItemId(f.uuid(2)),
      name: 'Gem Quest',
      gemsPerHour: 2400000,
    ),
  );
  final timeAward = await createItem(
    tester,
    fixture,
    journeyAward(
      id: ItemId(f.uuid(3)),
      name: 'Time Award',
      priceCoins: 1000000,
      timeGrantSeconds: 300,
    ),
  );
  await createItem(
    tester,
    fixture,
    journeyAward(
      id: ItemId(f.uuid(4)),
      name: 'Food',
      priceCoins: 1000000,
      budgetMinorUnits: 3500,
    ),
  );
  await createItem(
    tester,
    fixture,
    journeyAward(
      id: ItemId(f.uuid(5)),
      name: 'Getaway',
      priceCoins: 1000000,
      timeGrantSeconds: 300,
      budgetMinorUnits: 1000,
    ),
  );

  // Two active minutes earn the four Coins the three Award variants cost.
  await runQuest(tester, fixture, coinQuest, 120000);

  // Both Quest variants appear on Home; Awards await a purchase.
  await waitUntil(
    tester,
    () => find.text('Quest · 10m').evaluate().length == 2,
    'Both Quest variants are listed',
  );
  await tapText(tester, 'Shop');
  await settle(tester);
  expect(find.text('Redeem Time Award'), findsOneWidget);
  await revealOffer(tester, 'Redeem Food');
  expect(find.text('Redeem Food'), findsOneWidget);
  await revealOffer(tester, 'Redeem Getaway');
  expect(find.text('Redeem Getaway'), findsOneWidget);
  await tapText(tester, 'Home');
  await settle(tester);

  // An appearance-only edit changes no economics.
  final walletBefore = await readWallet(tester, fixture);
  final historyBefore = await readStore<List<String>>(
    tester,
    fixture,
    (records) async => [
      for (final entry in await records.ledger()) entry.id.value,
    ],
  );
  final edited = await use(tester, fixture, (composition) async {
    return f.success(
      await composition.items.saveItem(
        operationId: fixture.operation(),
        item: journeyQuest(
          id: coinQuest.id,
          name: 'Coin Quest',
          coinsPerHour: 120000000,
          iconKey: 'coffee',
          colorArgb: 0xff204080,
          revision: coinQuest.revision.value,
        ),
        expectedRevision: coinQuest.revision,
      ),
    );
  });
  expect(edited.revision.value, coinQuest.revision.value + 1);
  expect(edited.type, ItemType.quest, reason: 'Type never follows appearance');
  final editedConfig = edited.configuration as QuestConfiguration;
  final originalConfig = coinQuest.configuration as QuestConfiguration;
  expect(editedConfig.duration, originalConfig.duration);
  expect(
    editedConfig.ratesPerHour.coins.units,
    originalConfig.ratesPerHour.coins.units,
  );
  expect(
    editedConfig.ratesPerHour.gems.units,
    originalConfig.ratesPerHour.gems.units,
  );
  var wallet = await readWallet(tester, fixture);
  expect(
    wallet.balances.coins.units,
    walletBefore.balances.coins.units,
    reason: 'An appearance edit moves no balance',
  );
  expect(wallet.balances.gems.units, walletBefore.balances.gems.units);
  expect(
    await readLedgerIds(tester, fixture),
    historyBefore,
    reason: 'An appearance edit writes no history',
  );
  await settle(tester);
  final editedTile = tester.widget<ItemTile>(
    find.byWidgetPredicate(
      (widget) => widget is ItemTile && widget.name == 'Coin Quest',
    ),
  );
  expect(editedTile.iconKey, 'coffee');
  expect(editedTile.palette.accent.toARGB32(), 0xff204080);

  // Own the time-only Award so one Quest and one Award share the tile list.
  await redeem(tester, fixture, timeAward, 1);
  await waitUntil(
    tester,
    () => find.text('Award · 5m').evaluate().isNotEmpty,
    'The purchased time allowance appears on Home',
  );
  // The identical gamepad icon and plum color identify a Quest and an Award
  // side by side; Coin Quest now wears the coffee icon and another color, so
  // the unchanged pair proves type is a label, never a function of appearance.
  final tiles = tester.widgetList<ItemTile>(
    find.byWidgetPredicate(
      (widget) =>
          widget is ItemTile &&
          widget.iconKey == 'gamepad' &&
          widget.palette.accent.toARGB32() == 0xff883366,
    ),
  );
  expect(tiles.map((tile) => (tile.name, tile.kind)).toSet(), {
    ('Gem Quest', TileKind.quest),
    ('Time Award', TileKind.award),
  }, reason: 'The same icon and color serve both item types');

  // Earnings still follow the original rates after the appearance edit; the
  // baseline sits after the purchase so only earning moves the balance.
  final beforeEarning = await readWallet(tester, fixture);
  await runQuest(tester, fixture, edited, 60000);
  wallet = await readWallet(tester, fixture);
  expect(
    wallet.balances.coins.units - beforeEarning.balances.coins.units,
    2000000,
    reason: 'A Coins-only Quest earns only Coins at its configured rate',
  );
  expect(
    wallet.balances.gems.units - beforeEarning.balances.gems.units,
    0,
    reason: 'A Coins-only Quest earns no Gems',
  );
  await runQuest(tester, fixture, gemQuest, 60000);
  wallet = await readWallet(tester, fixture);
  expect(
    wallet.balances.gems.units - beforeEarning.balances.gems.units,
    40000,
    reason: 'A Gems-only Quest earns only Gems at its configured rate',
  );

  // Award variants grant exactly their configured dimensions.
  final food = await readStore<Item?>(
    tester,
    fixture,
    (records) => records.item(ItemId(f.uuid(4))),
  );
  final getaway = await readStore<Item?>(
    tester,
    fixture,
    (records) => records.item(ItemId(f.uuid(5))),
  );
  await redeem(tester, fixture, food!, 1);
  await redeem(tester, fixture, getaway!, 1);
  final balances = await readStore<Map<ItemId, AwardBalance>>(
    tester,
    fixture,
    (records) async => {
      for (final balance in await records.awards()) balance.awardId: balance,
    },
  );
  expect(balances[food.id]!.time, isNull, reason: 'Budget-only has no time');
  expect(balances[food.id]!.budget!.minorUnits, 3500);
  expect(balances[getaway.id]!.time!.value, 300000);
  expect(balances[getaway.id]!.budget!.minorUnits, 1000);
  expect(await readMismatches(tester, fixture), isEmpty);
  await endJourney(tester);
}

Future<List<String>> readLedgerIds(
  WidgetTester tester,
  JourneyFixture fixture,
) => readStore(
  tester,
  fixture,
  (records) async => [
    for (final entry in await records.ledger()) entry.id.value,
  ],
);

/// Journey: the one global session slot. A second timed item cannot start
/// while another session runs or is paused; cancel keeps the current session;
/// expense entry opens without ending anything by itself.
Future<void> journeyOneSessionConflict(
  WidgetTester tester,
  JourneyFixture fixture,
) async {
  await pumpJourneyApp(tester, fixture);
  await skipOnboarding(tester);
  final focus = await createItem(
    tester,
    fixture,
    journeyQuest(id: ItemId(f.uuid(1)), name: 'Focus'),
  );
  final walker = await createItem(
    tester,
    fixture,
    journeyQuest(id: ItemId(f.uuid(2)), name: 'Walker'),
  );
  final food = await createItem(
    tester,
    fixture,
    journeyAward(
      id: ItemId(f.uuid(3)),
      name: 'Food',
      priceCoins: 1000000,
      budgetMinorUnits: 3500,
    ),
  );

  // A running session occupies the slot; thirty active seconds also earn
  // the one Coin the later Food redemption needs.
  final started = await startQuestSession(tester, fixture, focus);
  fixture.clock.advance(30000);
  await tapTile(tester, 'Walker');
  await awaitFinder(
    tester,
    find.text('A session is already active'),
    'Selecting another timed item presents the conflict',
  );
  await tapText(tester, 'Cancel');
  await settle(tester);
  var active = await readStore<Session?>(
    tester,
    fixture,
    (records) => records.activeSession(),
  );
  expect(
    active!.itemSnapshot.id,
    focus.id,
    reason: 'Canceling the conflict keeps the current session',
  );

  // The command path enforces the same rule.
  final rejected = await use(tester, fixture, (composition) async {
    return composition.sessions.startSession(
      operationId: fixture.operation(),
      itemId: walker.id,
      expectedItemRevision: walker.revision,
      conflictChoice: SessionConflictChoice.cancel,
    );
  });
  expect(
    rejected,
    isA<Failure<SessionMutation>>(),
    reason: 'A second session command cannot begin',
  );
  expect(
    (rejected as Failure<SessionMutation>).error,
    isA<ActiveSessionConflict>(),
  );

  // A paused session still occupies the slot.
  final paused = await use(tester, fixture, (composition) async {
    return f.success(
      await composition.sessions.pauseSession(
        operationId: fixture.operation(),
        sessionId: started.session.id,
        expectedRevision: started.session.revision,
      ),
    );
  });
  await tapTile(tester, 'Walker');
  await awaitFinder(
    tester,
    find.textContaining('Focus is paused'),
    'The conflict explains the paused occupant',
  );
  await tapText(tester, 'Cancel');
  await settle(tester);
  active = await readStore<Session?>(
    tester,
    fixture,
    (records) => records.activeSession(),
  );
  expect(active!.id, paused.session.id);

  // After the slot frees, the same tap starts the next session.
  await use(tester, fixture, (composition) async {
    return f.success(
      await composition.sessions.endSession(
        operationId: fixture.operation(),
        sessionId: paused.session.id,
        expectedRevision: paused.session.revision,
      ),
    );
  });
  await launchByName(tester, 'Walker');
  expect(find.text('Quest session'), findsOneWidget);
  active = await readStore<Session?>(
    tester,
    fixture,
    (records) => records.activeSession(),
  );
  expect(active!.itemSnapshot.id, walker.id);
  await tapWhenEnabled(tester, 'End & keep earnings');
  await waitUntil(
    tester,
    () => find.text('Quest session').evaluate().isEmpty,
    'Ending frees the slot again',
  );

  // Opening an expense never ends the running session by itself.
  final second = await startQuestSession(tester, fixture, focus);
  await redeem(tester, fixture, food, 1);
  await tapTile(tester, 'Food');
  await awaitFinder(
    tester,
    find.text('Enjoy your Food'),
    'The expense entry opens during a session',
  );
  await tapText(tester, 'Cancel');
  await settle(tester);
  active = await readStore<Session?>(
    tester,
    fixture,
    (records) => records.activeSession(),
  );
  expect(
    active!.id,
    second.session.id,
    reason: 'Canceling an expense leaves the session running',
  );
  await use(tester, fixture, (composition) async {
    return f.success(
      await composition.sessions.endSession(
        operationId: fixture.operation(),
        sessionId: second.session.id,
        expectedRevision: second.session.revision,
      ),
    );
  });
  expect(await readMismatches(tester, fixture), isEmpty);
  await endJourney(tester);
}

/// Journey: purchases pool into one balance, replay by operation ID debits
/// once, conflicting reuse and unaffordable quantities change nothing, and
/// the Shop dialog states the pooled result.
///
/// The authoritative example: an Award with 45 minutes left redeems three
/// ten-minute packs and its single Home tile shows 75 minutes.
Future<void> journeyPurchasePoolingAndIdempotency(
  WidgetTester tester,
  JourneyFixture fixture,
) async {
  await pumpJourneyApp(tester, fixture);
  await skipOnboarding(tester);
  final earner = await createItem(
    tester,
    fixture,
    journeyQuest(
      id: ItemId(f.uuid(1)),
      name: 'Earner',
      coinsPerHour: 120000000,
    ),
  );
  final gaming = await createItem(
    tester,
    fixture,
    journeyAward(
      id: ItemId(f.uuid(2)),
      name: 'Gaming',
      priceCoins: 1000000,
      timeGrantSeconds: 900,
    ),
  );

  // Earn ten Coins, then buy three fifteen-minute packs.
  await runQuest(tester, fixture, earner, 300000);
  var wallet = await readWallet(tester, fixture);
  expect(wallet.balances.coins.units, 10000000);
  await redeem(tester, fixture, gaming, 3);
  wallet = await readWallet(tester, fixture);
  expect(wallet.balances.coins.units, 7000000);
  var balance = await readStore<AwardBalance?>(
    tester,
    fixture,
    (records) => records.award(gaming.id),
  );
  expect(balance!.time!.value, 2700000, reason: '45 minutes pooled');

  // Grant edits apply to future purchases only.
  final repackaged = await use(tester, fixture, (composition) async {
    return f.success(
      await composition.items.saveItem(
        operationId: fixture.operation(),
        item: journeyAward(
          id: gaming.id,
          name: 'Gaming',
          priceCoins: 1000000,
          timeGrantSeconds: 600,
          revision: gaming.revision.value,
        ),
        expectedRevision: gaming.revision,
      ),
    );
  });
  balance = await readStore<AwardBalance?>(
    tester,
    fixture,
    (records) => records.award(gaming.id),
  );
  expect(
    balance!.time!.value,
    2700000,
    reason: 'A grant edit never rewrites the owned balance',
  );

  // Redeem three of the new ten-minute packs through the Shop dialog.
  await tapText(tester, 'Shop');
  await settle(tester);
  await tapText(tester, 'Redeem Gaming');
  await awaitFinder(
    tester,
    find.byKey(const ValueKey('purchase-quantity')),
    'The redemption dialog opened',
  );
  await enterQuantity(tester, '3');
  await awaitFinder(
    tester,
    find.textContaining('New balance: 1h 15m'),
    'The dialog previews the pooled balance',
  );
  await tapWhenEnabled(tester, 'Redeem 3 packs');
  await waitUntil(
    tester,
    () => find.byKey(const ValueKey('purchase-quantity')).evaluate().isEmpty,
    'The purchase dialog closes on its receipt',
  );
  await tapText(tester, 'Home');
  await settle(tester);
  expect(
    find.text('Award · 1h 15m'),
    findsOneWidget,
    reason: 'One tile shows the pooled 75 minutes',
  );
  expect(
    tester.widgetList<ItemTile>(
      find.byWidgetPredicate(
        (widget) => widget is ItemTile && widget.name == 'Gaming',
      ),
    ),
    hasLength(1),
    reason: 'No extra tiles are created',
  );
  balance = await readStore<AwardBalance?>(
    tester,
    fixture,
    (records) => records.award(gaming.id),
  );
  expect(
    balance!.time!.value,
    4500000,
    reason: '45 + 3 × 10 minutes stored once',
  );
  wallet = await readWallet(tester, fixture);
  expect(wallet.balances.coins.units, 4000000);

  // A duplicate submission with the same operation ID returns the original
  // result without debiting or granting again.
  final operation = fixture.operation();
  final first = await redeem(
    tester,
    fixture,
    repackaged,
    1,
    operation: operation,
  );
  final replay = await redeem(
    tester,
    fixture,
    repackaged,
    1,
    operation: operation,
  );
  expect(
    replay.wallet.balances.coins.units,
    first.wallet.balances.coins.units,
    reason: 'Replays return the original commitment',
  );
  wallet = await readWallet(tester, fixture);
  expect(wallet.balances.coins.units, 3000000, reason: 'Debited exactly once');
  balance = await readStore<AwardBalance?>(
    tester,
    fixture,
    (records) => records.award(gaming.id),
  );
  expect(balance!.time!.value, 5100000, reason: 'Granted exactly once');
  final replayEntries = await readStore<List<LedgerEntry>>(
    tester,
    fixture,
    (records) => records.ledger(operationId: operation),
  );
  expect(
    replayEntries,
    hasLength(2),
    reason: 'One price entry and one grant entry, not two',
  );

  // Reusing the ID with different arguments is rejected without effects.
  final conflicting = await use(tester, fixture, (composition) async {
    return composition.economy.redeemAward(
      operationId: operation,
      awardId: repackaged.id,
      expectedRevision: repackaged.revision,
      quantity: PurchaseQuantity(2),
    );
  });
  expect(
    conflicting,
    isA<Failure<EconomicState>>(),
    reason: 'Conflicting operation reuse is rejected',
  );
  wallet = await readWallet(tester, fixture);
  expect(wallet.balances.coins.units, 3000000);

  // An unaffordable quantity is refused without any change.
  final unaffordable = await use(tester, fixture, (composition) async {
    return composition.economy.redeemAward(
      operationId: fixture.operation(),
      awardId: repackaged.id,
      expectedRevision: repackaged.revision,
      quantity: PurchaseQuantity(100),
    );
  });
  final failure = unaffordable as Failure<EconomicState>;
  expect(failure.error, isA<InsufficientFunds>());
  expect(
    (failure.error as InsufficientFunds).coins,
    isTrue,
    reason: 'The short currency is identified',
  );
  wallet = await readWallet(tester, fixture);
  expect(wallet.balances.coins.units, 3000000);
  balance = await readStore<AwardBalance?>(
    tester,
    fixture,
    (records) => records.award(gaming.id),
  );
  expect(balance!.time!.value, 5100000);

  // The dialog itself names the shortfall and refuses to submit.
  await tapText(tester, 'Shop');
  await settle(tester);
  await tapText(tester, 'Redeem Gaming');
  await awaitFinder(
    tester,
    find.byKey(const ValueKey('purchase-quantity')),
    'The redemption dialog reopened',
  );
  await enterQuantity(tester, '100');
  await awaitFinder(
    tester,
    find.text('You need 97 more Coins.'),
    'The dialog states which currency is insufficient',
  );
  final submit = tester.widgetList<TroveButton>(
    find.widgetWithText(TroveButton, 'Redeem 100 packs'),
  );
  expect(
    submit.every((button) => button.onPressed == null),
    isTrue,
    reason: 'An unaffordable purchase cannot be submitted',
  );
  await tapText(tester, 'Cancel');
  await settle(tester);
  expect(await readMismatches(tester, fixture), isEmpty);
  await endJourney(tester);
}

/// Journey: budget expenses stay within the remaining allowance, replay by
/// operation ID debits once, a combined Award survives a zero dimension, and
/// expense consent can end the occupying session atomically.
Future<void> journeyExpenseBudgetAndExhaustion(
  WidgetTester tester,
  JourneyFixture fixture,
) async {
  await pumpJourneyApp(tester, fixture);
  await skipOnboarding(tester);
  final earner = await createItem(
    tester,
    fixture,
    journeyQuest(
      id: ItemId(f.uuid(1)),
      name: 'Earner',
      coinsPerHour: 120000000,
    ),
  );
  final food = await createItem(
    tester,
    fixture,
    journeyAward(
      id: ItemId(f.uuid(2)),
      name: 'Food',
      priceCoins: 1000000,
      budgetMinorUnits: 3500,
    ),
  );
  final getaway = await createItem(
    tester,
    fixture,
    journeyAward(
      id: ItemId(f.uuid(3)),
      name: 'Getaway',
      priceCoins: 1000000,
      timeGrantSeconds: 300,
      budgetMinorUnits: 1000,
    ),
  );
  await runQuest(tester, fixture, earner, 180000); // Six Coins.
  await redeem(tester, fixture, food, 1);
  var wallet = await readWallet(tester, fixture);
  expect(wallet.balances.coins.units, 5000000);
  // Dismiss the repository-driven Earner receipt now so the later Getaway
  // receipt assertions can only be satisfied by that session's own receipt.
  await dismissSessionResult(tester);

  // Record $12.50 of the $35 allowance through the real expense dialog.
  await tapTile(tester, 'Food');
  await awaitFinder(
    tester,
    find.text('Enjoy your Food'),
    'The expense entry opened',
  );
  await enterExpenseAmount(tester, '12.5');
  await awaitFinder(
    tester,
    find.text('USD 22.50 stays in My Trove'),
    'The dialog previews the remaining budget',
  );
  await tapText(tester, 'Record USD 12.50');
  await awaitFinder(
    tester,
    find.text('Expense recorded'),
    'The expense committed',
  );
  await tapText(tester, 'Done');
  await settle(tester);
  var balance = await readStore<AwardBalance?>(
    tester,
    fixture,
    (records) => records.award(food.id),
  );
  expect(
    balance!.budget!.minorUnits,
    2250,
    reason: r'$35 minus $12.50 leaves $22.50',
  );
  expect(
    find.text('Award · USD 22.50'),
    findsOneWidget,
    reason: 'The same reward keeps its single tile',
  );

  // An expense above the remaining allowance is not committed.
  await tapTile(tester, 'Food');
  await awaitFinder(
    tester,
    find.text('Enjoy your Food'),
    'The expense entry reopened',
  );
  await enterExpenseAmount(tester, '30');
  await tapWhenEnabled(tester, 'Record expense');
  await awaitFinder(
    tester,
    find.textContaining('no more than USD 22.50'),
    'The rejection names the remaining allowance',
  );
  await tapText(tester, 'Cancel');
  await settle(tester);
  balance = await readStore<AwardBalance?>(
    tester,
    fixture,
    (records) => records.award(food.id),
  );
  expect(balance!.budget!.minorUnits, 2250, reason: 'Nothing was committed');
  final foodLedger = await readStore<List<LedgerEntry>>(
    tester,
    fixture,
    (records) => records.ledger(itemId: food.id),
  );
  expect(
    foodLedger.where(isUsdSpent),
    hasLength(1),
    reason: 'Only the valid expense is stored',
  );

  // A duplicate expense submission debits once.
  final expenseOperation = fixture.operation();
  Future<EconomicState> submitExpense() => use(tester, fixture, (composition) {
    return composition.economy
        .recordExpense(
          operationId: expenseOperation,
          awardId: food.id,
          expectedBalanceRevision: balance!.revision,
          expense: BudgetAmount(
            BudgetCurrency.fromMetadata('USD', f.metadata),
            500,
          ),
          conflictChoice: SessionConflictChoice.cancel,
        )
        .then((result) => f.success(result));
  });
  final firstExpense = await submitExpense();
  final replayedExpense = await submitExpense();
  expect(
    replayedExpense.wallet.balances.coins.units,
    firstExpense.wallet.balances.coins.units,
    reason: 'Expense replay returns the original commitment',
  );
  balance = await readStore<AwardBalance?>(
    tester,
    fixture,
    (records) => records.award(food.id),
  );
  expect(
    balance!.budget!.minorUnits,
    1750,
    reason: r'$22.50 minus one $5 expense',
  );

  // Combined Award: partial time use preserves the unused allowance.
  await redeem(tester, fixture, getaway, 1);
  wallet = await readWallet(tester, fixture);
  expect(wallet.balances.coins.units, 4000000);
  await launchByName(tester, 'Getaway');
  await tapText(tester, 'Use time');
  await settle(tester);
  fixture.clock.advance(200000);
  await settle(tester);
  await tapWhenEnabled(tester, 'End & keep remaining time');
  await waitUntil(
    tester,
    () => find.text('Reward session').evaluate().isEmpty,
    'Ending the Award run returns Home',
  );
  await dismissSessionResult(tester);
  await settle(tester);
  balance = await readStore<AwardBalance?>(
    tester,
    fixture,
    (records) => records.award(getaway.id),
  );
  expect(
    balance!.time!.value,
    100000,
    reason: 'Ending early preserves the unused time',
  );
  expect(balance.budget!.minorUnits, 1000);
  expect(
    find.text('Award · 1m 40s · USD 10.00'),
    findsOneWidget,
    reason: 'Both dimensions stay on one tile',
  );

  // Zero time with an unused budget keeps the reward on Home.
  final finalRun = await startQuestSession(tester, fixture, getaway);
  expect(
    finalRun.session.duration.value,
    100000,
    reason: 'An Award run uses its available pooled time',
  );
  // Let Home render the occupying run before it completes, so the slot
  // watch sees the active-to-free transition and posts the receipt.
  await waitUntil(
    tester,
    () => find.byType(CompactSessionSlot).evaluate().isNotEmpty,
    'The final run occupies the session slot on Home',
  );
  fixture.clock.advance(110000); // Past the remaining 100 seconds.
  await use(
    tester,
    fixture,
    (composition) => composition.lifecycle.reconcile(),
  );
  await awaitFinder(
    tester,
    find.textContaining('Getaway completed'),
    'The final time allowance completed',
  );
  balance = await readStore<AwardBalance?>(
    tester,
    fixture,
    (records) => records.award(getaway.id),
  );
  expect(balance!.time!.value, 0);
  expect(balance.budget!.minorUnits, 1000);
  expect(
    find.text('Award · 0s · USD 10.00'),
    findsOneWidget,
    reason: 'A combined reward remains while any balance is unused',
  );

  // Expense consent can end the occupying session in the same transaction.
  final occupying = await startQuestSession(tester, fixture, earner);
  await tapTile(tester, 'Getaway');
  await tapText(tester, 'Record expense');
  await awaitFinder(
    tester,
    find.text('Enjoy your Getaway'),
    'The expense entry opened',
  );
  await enterExpenseAmount(tester, '5');
  await tapWhenEnabled(tester, 'Record USD 5.00');
  await awaitFinder(
    tester,
    find.text('A session is already active'),
    'Recording during a session asks for consent',
  );
  await tapText(tester, 'End current session and continue');
  await awaitFinder(
    tester,
    find.text('Expense recorded'),
    'The consented expense committed',
  );
  await tapText(tester, 'Done');
  await settle(tester);
  final active = await readStore<Session?>(
    tester,
    fixture,
    (records) => records.activeSession(),
  );
  expect(active, isNull, reason: 'The occupying session ended');
  final endedOccupier = await readStore<Session?>(
    tester,
    fixture,
    (records) => records.session(occupying.session.id),
  );
  expect(endedOccupier!.status, SessionStatus.ended);
  balance = await readStore<AwardBalance?>(
    tester,
    fixture,
    (records) => records.award(getaway.id),
  );
  expect(balance!.budget!.minorUnits, 500);

  // Exhausting every dimension removes the tile but not the catalog or
  // history.
  await tapTile(tester, 'Getaway');
  await awaitFinder(
    tester,
    find.text('Enjoy your Getaway'),
    'The use choice opened',
  );
  await tapText(tester, 'Record expense');
  await awaitFinder(
    tester,
    find.text('Enjoy your Getaway'),
    'The last expense entry opened',
  );
  await enterExpenseAmount(tester, '5');
  await tapWhenEnabled(tester, 'Record USD 5.00');
  await awaitFinder(
    tester,
    find.text('Expense recorded'),
    'The final expense committed',
  );
  await tapText(tester, 'Done');
  await settle(tester);
  await waitUntil(
    tester,
    () => find
        .byWidgetPredicate(
          (widget) => widget is ItemTile && widget.name == 'Getaway',
        )
        .evaluate()
        .isEmpty,
    'The exhausted Award leaves Home',
  );
  balance = await readStore<AwardBalance?>(
    tester,
    fixture,
    (records) => records.award(getaway.id),
  );
  expect(balance!.isExhausted, isTrue);
  expect(balance.time!.value, 0);
  expect(balance.budget!.minorUnits, 0);
  final getawayLedger = await readStore<List<LedgerEntry>>(
    tester,
    fixture,
    (records) => records.ledger(itemId: getaway.id),
  );
  expect(getawayLedger, isNotEmpty, reason: 'History is retained');
  await tapText(tester, 'Shop');
  await settle(tester);
  await revealOffer(tester, 'Redeem Getaway');
  expect(
    find.text('Redeem Getaway'),
    findsOneWidget,
    reason: 'The catalog definition survives exhaustion',
  );
  expect(await readMismatches(tester, fixture), isEmpty);
  await endJourney(tester);
}

/// Journey: a double tap on an idle Quest opens centered configuration with
/// no session, earning event, wallet change or notification intent.
Future<void> journeyDoubleTapConfigures(
  WidgetTester tester,
  JourneyFixture fixture,
) async {
  await pumpJourneyApp(tester, fixture);
  await skipOnboarding(tester);
  await createItem(
    tester,
    fixture,
    journeyQuest(id: ItemId(f.uuid(1)), name: 'Focus'),
  );
  final walletBefore = await readWallet(tester, fixture);
  final historyBefore = await readLedgerIds(tester, fixture);

  await waitForTile(tester, 'Focus');
  final tile = launcher('Focus');
  await tester.ensureVisible(tile);
  await settle(tester);
  await tester.tap(tile);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tap(tile);
  await settle(tester);
  await awaitFinder(
    tester,
    find.byKey(const ValueKey('Item name')),
    'The double tap opened the centered configuration',
  );
  expect(
    find.text('Quest session'),
    findsNothing,
    reason: 'The first tap of a double tap never starts a session',
  );
  final active = await readStore<Session?>(
    tester,
    fixture,
    (records) => records.activeSession(),
  );
  expect(active, isNull, reason: 'No session occupies the slot');
  final wallet = await readWallet(tester, fixture);
  expect(
    wallet.balances.coins.units,
    walletBefore.balances.coins.units,
    reason: 'No currency moved',
  );
  expect(wallet.balances.gems.units, walletBefore.balances.gems.units);
  expect(
    await readLedgerIds(tester, fixture),
    historyBefore,
    reason: 'No earning event started',
  );
  final intents = await readStore<List<NotificationIntent>>(
    tester,
    fixture,
    (records) => records.notificationIntents(),
  );
  expect(intents, isEmpty, reason: 'No completion was scheduled');
  await tapText(tester, 'Cancel');
  await settle(tester);
  expect(
    find.byKey(const ValueKey('Item name')),
    findsNothing,
    reason: 'The editor closes without saving',
  );
  expect(await readMismatches(tester, fixture), isEmpty);
  await endJourney(tester);
}

/// Journey: Stats stacks all four periods, filters by category and item,
/// keeps one unit per measure, and agrees with the committed ledger in every
/// timeframe.
Future<void> journeyStatsAgreesWithLedger(
  WidgetTester tester,
  JourneyFixture fixture,
) async {
  await pumpJourneyApp(tester, fixture);
  await skipOnboarding(tester);
  final reader = await createItem(
    tester,
    fixture,
    journeyQuest(
      id: ItemId(f.uuid(1)),
      name: 'Reader',
      coinsPerHour: 120000000,
    ),
  );
  final walker = await createItem(
    tester,
    fixture,
    journeyQuest(
      id: ItemId(f.uuid(2)),
      name: 'Walker',
      coinsPerHour: 120000000,
    ),
  );
  final food = await createItem(
    tester,
    fixture,
    journeyAward(
      id: ItemId(f.uuid(3)),
      name: 'Food',
      priceCoins: 1000000,
      budgetMinorUnits: 3500,
    ),
  );

  // Deterministic history across two years, weeks and days.
  atDay(fixture, DateTime.utc(2025, 12, 31));
  await runQuest(tester, fixture, reader, 120000);
  atDay(fixture, DateTime.utc(2026, 1, 13));
  await runQuest(tester, fixture, reader, 180000);
  atDay(fixture, DateTime.utc(2026, 1, 14));
  await runQuest(tester, fixture, walker, 120000);
  atDay(fixture, DateTime.utc(2026, 1, 15));
  await runQuest(tester, fixture, reader, 60000);
  await redeem(tester, fixture, food, 1);
  final balance = await readStore<AwardBalance?>(
    tester,
    fixture,
    (records) => records.award(food.id),
  );
  await use(
    tester,
    fixture,
    (composition) => composition.economy.recordExpense(
      operationId: fixture.operation(),
      awardId: food.id,
      expectedBalanceRevision: balance!.revision,
      expense: BudgetAmount(
        BudgetCurrency.fromMetadata('USD', f.metadata),
        1250,
      ),
      conflictChoice: SessionConflictChoice.cancel,
    ),
  );

  final entries = await readLedger(tester, fixture);
  final dailyStart = DateTime.utc(2026, 1, 15);
  final weeklyStart = dailyStart.subtract(
    Duration(days: dailyStart.weekday - 1),
  );

  await tapText(tester, 'Stats');
  await settle(tester);
  await awaitFinder(
    tester,
    find.text('Your progress'),
    'The Stats screen opened',
  );
  // The unit caption sits at the top of the lazily built list.
  expect(
    find.textContaining('Committed activity · min'),
    findsOneWidget,
    reason: 'The unit matches the selected measure',
  );
  expect(
    find.text('Daily · 15 Jan 2026'),
    findsOneWidget,
    reason: 'Daily uses hours of the selected day',
  );
  await revealChart(tester, find.text('Weekly · 12 Jan – 18 Jan 2026'));
  expect(find.text('Weekly · 12 Jan – 18 Jan 2026'), findsOneWidget);
  await revealChart(tester, find.text('Monthly · Jan 2026'));
  expect(find.text('Monthly · Jan 2026'), findsOneWidget);
  await revealChart(tester, find.text('Yearly · 2026'));
  expect(find.text('Yearly · 2026'), findsOneWidget);

  // Every period's chart total equals its ledger-derived total; each chart is
  // read right after being scrolled into the built viewport.
  Finder chartOf(StatsPeriod period) => find.byWidgetPredicate(
    (widget) => widget is StatsChart && widget.period == period,
  );

  Future<int> totalOf(StatsPeriod period) async {
    await revealChart(tester, chartOf(period));
    final chart = tester.widget<StatsChart>(chartOf(period));
    var total = 0;
    for (final bucket in chart.buckets) {
      total += bucket.value;
    }
    return total;
  }

  expect(
    await totalOf(StatsPeriod.daily),
    sumWindow(
      entries,
      isQuestTime,
      dailyStart,
      dailyStart.add(const Duration(days: 1)),
    ),
    reason: 'Daily agrees with the ledger',
  );
  expect(
    await totalOf(StatsPeriod.weekly),
    sumWindow(
      entries,
      isQuestTime,
      weeklyStart,
      weeklyStart.add(const Duration(days: 7)),
    ),
    reason: 'Weekly agrees with the ledger',
  );
  expect(
    await totalOf(StatsPeriod.monthly),
    sumWindow(
      entries,
      isQuestTime,
      DateTime.utc(2026, 1, 1),
      DateTime.utc(2026, 2, 1),
    ),
    reason: 'Monthly agrees with the ledger',
  );
  expect(
    await totalOf(StatsPeriod.yearly),
    sumWindow(
      entries,
      isQuestTime,
      DateTime.utc(2026, 1, 1),
      DateTime.utc(2027, 1, 1),
    ),
    reason: 'Yearly agrees with the ledger',
  );
  expect(await totalOf(StatsPeriod.daily), 60000);
  expect(await totalOf(StatsPeriod.weekly), 360000);
  await revealChart(tester, find.text('6 min · Quest minutes'));
  // The summary captions below state presence, not uniqueness: the stacked
  // period cards repeat a metric's caption whenever their totals coincide,
  // and a tall native viewport builds several cards at once. The ledger
  // equality checks on each period's buckets are the real assertions.
  expect(find.text('6 min · Quest minutes'), findsWidgets);

  // Navigating one Yearly period back still agrees with the ledger.
  await revealChart(tester, chartOf(StatsPeriod.yearly));
  final previous = find
      .descendant(of: chartOf(StatsPeriod.yearly), matching: find.text('‹'))
      .last;
  await tester.ensureVisible(previous);
  await settle(tester);
  await tester.tap(previous);
  await awaitFinder(
    tester,
    find.text('Yearly · 2025'),
    'The previous year is reachable in the same screen',
  );
  expect(
    await totalOf(StatsPeriod.yearly),
    sumWindow(
      entries,
      isQuestTime,
      DateTime.utc(2025, 1, 1),
      DateTime.utc(2026, 1, 1),
    ),
    reason: 'The 2025 chart agrees with the ledger',
  );
  expect(await totalOf(StatsPeriod.yearly), 120000);

  // Return to the top of the list for filter interactions.
  await tester.dragUntilVisible(
    find.text('Your progress'),
    find.byKey(const PageStorageKey<String>('stats-scroll')),
    const Offset(0, 400),
    maxIteration: 30,
  );
  await settle(tester);

  // The individual item filter recomputes every period from the ledger.
  await tapText(tester, 'Filters: All · Quest minutes');
  await awaitFinder(
    tester,
    find.text('See your progress'),
    'The filters dialog opened',
  );
  await tapText(tester, 'All');
  await chooseFilterRow(tester, 'Reader');
  await tapText(tester, 'Apply filters');
  await awaitFinder(
    tester,
    find.text('Filters: Reader · Quest minutes'),
    'The item filter applied',
  );
  expect(
    await totalOf(StatsPeriod.weekly),
    sumWindow(
      entries,
      isQuestTime,
      weeklyStart,
      weeklyStart.add(const Duration(days: 7)),
      item: reader.id,
    ),
    reason: 'The filtered weekly chart agrees with the ledger',
  );
  await awaitFinder(
    tester,
    find.text('4 min · Quest minutes'),
    'The item-filtered chart reloaded',
  );
  expect(await totalOf(StatsPeriod.weekly), 240000);

  // Budget spending keeps its own currency unit and matches the ledger.
  await tester.dragUntilVisible(
    find.textContaining('Filters: Reader · Quest minutes'),
    find.byKey(const PageStorageKey<String>('stats-scroll')),
    const Offset(0, 400),
    maxIteration: 30,
  );
  await settle(tester);
  await tapText(tester, 'Filters: Reader · Quest minutes');
  await awaitFinder(
    tester,
    find.text('See your progress'),
    'The filters dialog reopened',
  );
  await tapText(tester, 'Reader');
  await chooseFilterRow(tester, 'All');
  await tapText(tester, 'Budget spent');
  await tapText(tester, 'Apply filters');
  await awaitFinder(
    tester,
    find.text('Filters: All · Budget spent'),
    'The budget measure applied',
  );
  expect(
    find.textContaining('Committed activity · USD'),
    findsOneWidget,
    reason: 'The unit follows the real spending currency',
  );
  // The refreshed chart summary is the readiness signal for its buckets.
  await awaitFinder(
    tester,
    find.text('12.50 USD · Budget spent'),
    'The budget chart reloaded',
  );
  expect(
    await totalOf(StatsPeriod.daily),
    sumWindow(
      entries,
      isUsdSpent,
      dailyStart,
      dailyStart.add(const Duration(days: 1)),
    ),
    reason: 'Daily spending agrees with the ledger',
  );
  expect(await totalOf(StatsPeriod.daily), 1250);
  expect(find.text('12.50 USD · Budget spent'), findsWidgets);

  // Currency earning is its own measure, still ledger-exact.
  await tester.dragUntilVisible(
    find.textContaining('Filters: All · Budget spent'),
    find.byKey(const PageStorageKey<String>('stats-scroll')),
    const Offset(0, 400),
    maxIteration: 30,
  );
  await settle(tester);
  await tapText(tester, 'Filters: All · Budget spent');
  await awaitFinder(
    tester,
    find.text('See your progress'),
    'The filters dialog reopened',
  );
  await tapText(tester, 'Coins earned');
  await tapText(tester, 'Apply filters');
  await awaitFinder(
    tester,
    find.text('Filters: All · Coins earned'),
    'The currency measure applied',
  );
  await awaitFinder(
    tester,
    find.text('2 Coins · Coins earned'),
    'The Coins chart reloaded',
  );
  expect(
    await totalOf(StatsPeriod.daily),
    sumWindow(
      entries,
      isCoins,
      dailyStart,
      dailyStart.add(const Duration(days: 1)),
    ),
    reason: 'Daily Coins agree with the ledger',
  );
  expect(await totalOf(StatsPeriod.daily), 2000000);
  expect(
    await totalOf(StatsPeriod.weekly),
    sumWindow(
      entries,
      isCoins,
      weeklyStart,
      weeklyStart.add(const Duration(days: 7)),
    ),
    reason: 'Weekly Coins agree with the ledger',
  );
  await revealChart(tester, find.text('12 Coins · Coins earned'));
  expect(find.text('12 Coins · Coins earned'), findsWidgets);
  expect(await readMismatches(tester, fixture), isEmpty);
  await endJourney(tester);
}
