import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app.dart';

void main() {
  testWidgets('launches Home and navigates across the native shell', (
    tester,
  ) async {
    await tester.pumpWidget(const MinutroveApp());
    expect(find.text('A little effort, a little treasure.'), findsOneWidget);
    expect(
      find.text('Development preview · Sample screens only'),
      findsOneWidget,
    );

    await tester.tap(find.text('Shop'));
    await tester.pumpAndSettle();
    expect(find.text('Make room for what you love.'), findsOneWidget);

    await tester.tap(find.text('Stats'));
    await tester.pumpAndSettle();
    expect(find.text('See your time add up.'), findsOneWidget);

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('A little effort, a little treasure.'), findsOneWidget);
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

    await tester.pumpWidget(const MinutroveApp());
    for (final destination in ['Home', 'Shop', 'Stats']) {
      await tester.tap(find.text(destination));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    }
    semantics.dispose();
  });
}
