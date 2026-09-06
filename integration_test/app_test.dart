import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:minutrove/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('MINUTROVE_NATIVE_XCTEST')) {
    // XCTest enables platform semantics after the app launches. Wait before
    // testWidgets records its handle baseline, so that platform-owned handle
    // is not mistaken for a handle leaked by the app during the test.
    setUpAll(() async {
      await Future<void>(() async {
        while (!binding.platformDispatcher.semanticsEnabled) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }).timeout(const Duration(seconds: 30));
    });
  }

  testWidgets('native launch and navigation smoke', (tester) async {
    app.main();
    await tester.pumpAndSettle();
    const destinations = {
      'Shop': 'Make room for what you love.',
      'Stats': 'See your time add up.',
      'Home': 'A little effort, a little treasure.',
    };
    for (final destination in destinations.entries) {
      await tester.tap(find.text(destination.key));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(destination.value), findsOneWidget);
    }
  });
}
