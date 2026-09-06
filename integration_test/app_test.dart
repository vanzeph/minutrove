import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:minutrove/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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
