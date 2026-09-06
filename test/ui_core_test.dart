import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/ui/core/component_gallery.dart';
import 'package:minutrove/ui/core/core.dart';

Widget host(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: TroveTokens.theme(),
  home: child,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = FontLoader('Nunito Sans')
      ..addFont(rootBundle.load('assets/fonts/NunitoSans.ttf'));
    await font.load();
  });

  test('currency formatting retains exact spendable integer precision', () {
    expect(formatMillionths(0), '0');
    expect(formatMillionths(1), '0.000001');
    expect(formatMillionths(1200000), '1.2');
    expect(formatMillionths(9223372036854775807), '9223372036854.775807');
    expect(() => formatMillionths(-1), throwsArgumentError);
  });

  test(
    'catalog is searchable, unique, licensed and entirely bundled',
    () async {
      expect(IconCatalog.icons.length, greaterThanOrEqualTo(64));
      expect(
        IconCatalog.icons.map((e) => e.key).toSet().length,
        IconCatalog.icons.length,
      );
      expect(IconCatalog.search('  GAMING ').single.key, 'gamepad');
      expect(IconCatalog.search('工作').single.key, 'briefcase');
      expect(IconCatalog.search('read book').single.key, 'book');
      expect(IconCatalog.search('no such icon'), isEmpty);
      for (final icon in IconCatalog.icons) {
        expect(await rootBundle.loadString(icon.asset), contains('<svg'));
      }
      for (final license in [
        'NUNITO_SANS_OFL.txt',
        'LUCIDE_LICENSE.txt',
        'MINUTROVE_LICENSE.txt',
      ]) {
        expect(
          (await rootBundle.loadString('assets/licenses/$license')).length,
          greaterThan(1000),
        );
      }
    },
  );

  test(
    'custom accents retain a distinguishable icon against their backing',
    () {
      for (var gray = 0; gray <= 255; gray++) {
        final color = Color.fromARGB(255, gray, gray, gray);
        final palette = ItemPalette.custom(color);
        expect(palette.accent, color);
        final a = palette.accent.computeLuminance();
        final b = palette.iconBackground.computeLuminance();
        final contrast = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        expect(contrast, greaterThanOrEqualTo(3));
      }
    },
  );

  testWidgets(
    'double tap configures without first activating; single tap defers',
    (tester) async {
      var starts = 0;
      var configures = 0;
      await tester.pumpWidget(
        host(
          Scaffold(
            body: SizedBox(
              width: 150,
              child: ItemTile(
                name: 'Game',
                kind: TileKind.quest,
                iconKey: 'gamepad',
                palette: ItemPalette.presets[1],
                summary: '25m',
                onActivate: () => starts++,
                onConfigure: () => configures++,
              ),
            ),
          ),
        ),
      );
      final tile = find.byType(ItemIcon);
      await tester.tap(tile);
      await tester.pump(const Duration(milliseconds: 80));
      expect(starts, 0);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(starts, 0);
      expect(configures, 1);
      await tester.tap(tile);
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(starts, 1);
      expect(configures, 1);
      await tester.tap(find.text('Configure'));
      await tester.pumpAndSettle();
      expect(starts, 1);
      expect(configures, 2);
    },
  );

  testWidgets(
    'appearance can be reused or recolored across either explicit type',
    (tester) async {
      await tester.pumpWidget(
        host(
          Scaffold(
            body: ItemTileGroup(
              title: 'Mixed',
              children: [
                for (final kind in TileKind.values)
                  ItemTile(
                    name: kind.name,
                    kind: kind,
                    iconKey: 'gamepad',
                    palette: ItemPalette.presets[kind.index],
                    summary: '25m',
                    onActivate: () {},
                    onConfigure: () {},
                  ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Quest · 25m'), findsOneWidget);
      expect(find.text('Award · 25m'), findsOneWidget);
      final icons = tester
          .widgetList<TroveIcon>(find.byType(TroveIcon))
          .toList();
      expect(icons.map((e) => e.iconKey), everyElement('gamepad'));
      expect(icons[0].color, isNot(icons[1].color));
    },
  );

  testWidgets('search selects a catalog key and handles empty results', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      host(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showIconPicker(
                  context: context,
                  selectedKey: 'book',
                  palette: ItemPalette.presets[0],
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'unknown activity');
    await tester.pumpAndSettle();
    expect(
      find.text('No icons found. Try another activity or object.'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextFormField), 'gaming');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gamepad'));
    await tester.pumpAndSettle();
    expect(result, 'gamepad');
  });

  testWidgets(
    'custom color validates, preserves invalid input and returns exact RGB',
    (tester) async {
      Color? result;
      await tester.pumpWidget(
        host(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showItemColorPicker(
                    context: context,
                    color: Colors.teal,
                    iconKey: 'gamepad',
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '#invalid');
      await tester.ensureVisible(find.text('Save color'));
      await tester.tap(find.text('Save color'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a six-digit hex color.'), findsOneWidget);
      expect(find.text('#invalid'), findsOneWidget);
      expect(result, isNull);
      await tester.enterText(find.byType(TextFormField), '#FAE123');
      await tester.ensureVisible(find.text('Save color'));
      await tester.tap(find.text('Save color'));
      await tester.pumpAndSettle();
      expect(result, const Color(0xfffae123));
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets('gallery and centered forms fit phone at ${scale}x text', (
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
      final semantics = tester.ensureSemantics();

      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(key: boundary, child: host(const ComponentGallery())),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      semantics.dispose();
      await capture(tester, boundary, 'gallery-${scale}x');
      await tester.ensureVisible(find.byType(ItemTile).first);
      await tester.pumpAndSettle();
      await capture(tester, boundary, 'gallery-scrolled-${scale}x');
      await tester.tap(find.text('Configure').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture(tester, boundary, 'form-${scale}x');
      await tester.enterText(
        find.byType(TextFormField).first,
        'Remember my text',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Close preview'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture(tester, boundary, 'form-keyboard-${scale}x');
      final dialogRect = tester.getRect(find.byType(Dialog));
      expect(
        dialogRect.center.dx,
        closeTo(tester.view.physicalSize.width / 2, 1),
      );
      expect(
        tester.getRect(find.text('Close preview')).bottom,
        lessThan(tester.view.physicalSize.height - 220),
      );
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller,
        isNull,
      );
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Remember my text'));
      await tester.pumpAndSettle();
      expect(find.text('Remember my text'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
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
    final directory = Directory('build/ui-evidence')
      ..createSync(recursive: true);
    File('${directory.path}/$name.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
