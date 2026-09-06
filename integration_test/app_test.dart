import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:minutrove/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native launch and navigation smoke', (tester) async {
    app.main();
    await tester.pumpAndSettle();
    for (final destination in ['Shop', 'Stats', 'Home']) {
      await tester.tap(find.text(destination));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(destination), findsOneWidget);
    }
  });
}
