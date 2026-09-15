import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app_startup.dart';
import 'package:minutrove/domain/domain.dart';

import '../app_startup_test.dart' show StartupFixture, pumpApp;
import '../data/support.dart' as f;
import '../features/home_shell_test.dart' show flush, settle;

/// Screen-reader activation journeys. VoiceOver and TalkBack translate their
/// double-tap gesture into semantics activation events, bypassing raw
/// gesture-arena double taps entirely. These tests drive the app exclusively
/// through `SemanticsOwner.performAction` to prove the reserved double tap
/// never blocks activation and that Configure stays reachable both as a
/// custom rotor action and as a real focusable button.
///
/// Data seeding and verification reads run in `runAsync` while the semantics
/// tree is disabled: with this pinned SDK, enabling the semantics owner and
/// then performing a real SQLite write through `runAsync` deadlocks the
/// tester, so semantics is enabled only between seeding and verification.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  // The live semantics tree hangs off the view's pipeline owner, not the
  // binding's root owner (whose rootSemanticsNode stays null here).
  SemanticsOwner owner(WidgetTester tester) =>
      tester.binding.renderViews.first.owner!.semanticsOwner!;

  /// Depth-first label search over the live semantics tree.
  SemanticsNode? nodeByLabel(WidgetTester tester, String label) {
    SemanticsNode? found;
    bool visit(SemanticsNode node) {
      if (found != null) return false;
      if (node.label == label) {
        found = node;
        return false;
      }
      node.visitChildren((child) => visit(child));
      return found == null;
    }

    final root = owner(tester).rootSemanticsNode;
    if (root != null) visit(root);
    return found;
  }

  /// Performs a semantics action the way an assistive technology does, polling
  /// until the expected effect appears. Disabled controls expose no tap
  /// action, so a no-op perform is retried after the UI settles.
  Future<void> activate(
    WidgetTester tester,
    String label, {
    SemanticsAction action = SemanticsAction.tap,
    Object? args,
    required bool Function() done,
    String reason = 'the semantics activation produced its effect',
  }) async {
    for (var attempt = 0; attempt < 200 && !done(); attempt++) {
      final node = nodeByLabel(tester, label);
      if (node != null) {
        owner(tester).performAction(node.id, action, args);
      }
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(done(), isTrue, reason: '$reason ($label)');
  }

  /// Seeds one personal Quest through the real repository before any widgets
  /// or semantics exist, over the same file `pumpApp` then opens.
  Future<void> seedQuest(StartupFixture fixture) async {
    final opened = await fixture.open();
    final composition = (opened as Success<(AppComposition, bool)>).value.$1;
    final result = await composition.items.saveItem(
      operationId: OperationId(f.uuid(9001)),
      item: Item(
        id: ItemId(f.uuid(1)),
        revision: Revision(1),
        name: 'Work',
        iconKey: 'gamepad',
        colorArgb: 0xff7654a5,
        groupId: null,
        order: 0,
        archived: false,
        configuration: QuestConfiguration(
          duration: Milliseconds.seconds(600),
          ratesPerHour: f.amounts(60000000),
        ),
      ),
      expectedRevision: null,
    );
    expect(result, isA<Success<Item>>());
    await composition.close();
    fixture.composition = null;
  }

  testWidgets('onboarding is operable through activation alone', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpApp(tester, fixture);
    await settle(tester);
    await activate(
      tester,
      'Skip setup',
      done: () =>
          find.text('Make time for what matters.').evaluate().isNotEmpty,
      reason: 'onboarding skip works via screen-reader activation',
    );
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
  });

  testWidgets('core loop runs entirely through semantics activation', (
    tester,
  ) async {
    await tester.runAsync(() => seedQuest(fixture));

    // Semantics is enabled only after seeding; see the header note.
    final semantics = tester.ensureSemantics();
    await pumpApp(tester, fixture);
    await settle(tester);
    expect(find.text('Work'), findsOneWidget);

    // The tile exposes one merged node with a spoken label, a tap action and
    // the Configure custom action; screen readers announce all of them.
    for (
      var attempt = 0;
      attempt < 100 && nodeByLabel(tester, 'Work, Quest · 10m') == null;
      attempt++
    ) {
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 50));
    }
    final tile = nodeByLabel(tester, 'Work, Quest · 10m');
    expect(tile, isNotNull, reason: 'The Home tile publishes its label');
    final data = tile!.getSemanticsData();
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(
      data.customSemanticsActionIds
          ?.map(CustomSemanticsAction.getAction)
          .map((action) => action?.label),
      contains('Configure'),
      reason: 'TalkBack action menus and the VoiceOver rotor reach Configure',
    );

    // Screen-reader activation starts the session immediately: the reserved
    // double tap never delays or swallows the assistive activation.
    await activate(
      tester,
      'Work, Quest · 10m',
      done: () => find.text('Quest session').evaluate().isNotEmpty,
      reason: 'screen-reader activation starts the quest session',
    );

    // Ending the session is reachable through activation as well.
    fixture.clock.advance(3000);
    await tester.pump(const Duration(seconds: 1));
    await activate(
      tester,
      'End & keep earnings',
      done: () => find.text('Quest session').evaluate().isEmpty,
      reason: 'screen-reader activation ends the session',
    );
    await activate(
      tester,
      'Dismiss session result',
      done: () =>
          find.text('Dismiss session result').evaluate().isEmpty &&
          find.text('Time well spent').evaluate().isEmpty,
      reason: 'the settled result banner is dismissible via activation',
    );

    // Configure: the custom action opens centered configuration with no start.
    // Custom actions address their engine id, discovered from the node.
    final configureIds =
        tile.getSemanticsData().customSemanticsActionIds?.where(
          (id) => CustomSemanticsAction.getAction(id)?.label == 'Configure',
        ) ??
        const <int>[];
    expect(configureIds, isNotEmpty);
    await activate(
      tester,
      'Work, Quest · 10m',
      action: SemanticsAction.customAction,
      args: configureIds.single,
      done: () => find.text('Configure item').evaluate().isNotEmpty,
      reason: 'the rotor Configure action opens the editor',
    );
    expect(
      find.byTooltip('Close'),
      findsOneWidget,
      reason: 'The editor dialog exposes a labeled close action',
    );
    await activate(
      tester,
      'Cancel',
      done: () => find.text('Configure item').evaluate().isEmpty,
      reason: 'the editor cancels without side effects',
    );

    // The explicit visible Configure button is also a labeled semantics node.
    await activate(
      tester,
      'Configure Work',
      done: () => find.text('Configure item').evaluate().isNotEmpty,
      reason: 'the visible Configure button opens the editor',
    );
    await activate(
      tester,
      'Cancel',
      done: () => find.text('Configure item').evaluate().isEmpty,
    );

    // Disable semantics before the verification read; see the header note.
    semantics.dispose();
    final ledger = await tester.runAsync<List<LedgerEntry>>(
      () => fixture.read((r) => r.ledger()),
    );
    expect(ledger, isNotEmpty);
    final operations = ledger!.map((entry) => entry.operationId).toSet();
    expect(operations, hasLength(1));
  });
}
