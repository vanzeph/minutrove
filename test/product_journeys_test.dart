import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/platform/audio/completion_chime.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/product_journeys.dart';

/// Runs the deterministic product acceptance journeys over an isolated ffi
/// SQLite database in the routine test suite. The native integration suite
/// runs the same journeys over the real on-device plugin.
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

  final chimeChannel = const MethodChannel(CompletionChime.channelName);
  late JourneyFixture fixture;
  setUp(() async {
    fixture = JourneyFixture(
      factory: databaseFactoryFfi,
      chime: CompletionChime(channel: chimeChannel),
    );
    await fixture.create();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(chimeChannel, (call) async => 'suppressed');
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(chimeChannel, null);
    await fixture.destroy();
  });

  testWidgets(
    'journey: exact earnings, pause, split sessions, one completion, restart',
    (tester) async {
      await journeyEarnPauseSplitCompleteRestart(tester, fixture);
    },
  );

  testWidgets(
    'journey: Quest and Award variants with independent icon and color',
    (tester) async {
      await journeyVariantsAndAppearanceIndependence(tester, fixture);
    },
  );

  testWidgets('journey: one session slot with explicit conflicts', (
    tester,
  ) async {
    await journeyOneSessionConflict(tester, fixture);
  });

  testWidgets(
    'journey: purchases pool allowances and stay idempotent and affordable',
    (tester) async {
      await journeyPurchasePoolingAndIdempotency(tester, fixture);
    },
  );

  testWidgets(
    'journey: expenses respect budgets and combined Awards exhaust last',
    (tester) async {
      await journeyExpenseBudgetAndExhaustion(tester, fixture);
    },
  );

  testWidgets('journey: double tap configures without starting', (
    tester,
  ) async {
    await journeyDoubleTapConfigures(tester, fixture);
  });

  testWidgets('journey: Stats filters agree with the ledger', (tester) async {
    await journeyStatsAgreesWithLedger(tester, fixture);
  });
}
