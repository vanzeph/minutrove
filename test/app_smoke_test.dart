import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_startup_test.dart' show StartupFixture, pumpApp, tapText;
import 'features/home_shell_test.dart' show settle;

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

  testWidgets('launches onboarding, then navigates the live shell', (
    tester,
  ) async {
    await pumpApp(tester, fixture);
    await settle(tester);
    // First run shows onboarding; skipping reaches the real empty Home.
    expect(find.text('Turn your time into treasure'), findsOneWidget);
    await tapText(tester, 'Skip setup');
    await settle(tester);
    expect(find.text('Make time for what matters.'), findsOneWidget);
    expect(find.text('0 Coins'), findsOneWidget);

    await tapText(tester, 'Shop');
    await settle(tester);
    expect(find.text('Reward Shop'), findsOneWidget);

    await tapText(tester, 'Stats');
    await settle(tester);
    expect(find.text('Your progress'), findsOneWidget);

    await tapText(tester, 'Home');
    await settle(tester);
    expect(find.text('Make time for what matters.'), findsOneWidget);
  });

  testWidgets('small phone supports large text and labeled tap targets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final semantics = tester.ensureSemantics();

    await pumpApp(tester, fixture);
    await settle(tester);
    await tapText(tester, 'Skip setup');
    await settle(tester);
    for (final destination in ['Shop', 'Stats', 'Home']) {
      await tapText(tester, destination);
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    }
    semantics.dispose();
  });
}
