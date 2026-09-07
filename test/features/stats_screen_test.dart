import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/stats/stats.dart';
import 'package:minutrove/features/stats/stats_chart.dart';

import '../data/support.dart' as f;
import 'home_shell_test.dart' show item, capture;

class FakeStatsSource implements StatsSource {
  StatsContext data = StatsContext(
    items: [
      item(id: 1, name: 'Focus'),
      item(id: 2, name: 'Old Focus', archived: true),
      item(id: 3, name: 'Coffee', award: true, time: false, budget: true),
      item(id: 4, name: 'Gaming', award: true),
    ],
    today: DayKey(2026, 9, 6),
    zone: f.zone,
  );
  final changes = StreamController<StatsContext>.broadcast();
  final requests = <List<StatsQuery>>[];
  final pending = <Completer<Result<List<List<StatsBucket>>>>>[];
  bool hold = false;
  bool fail = false;
  bool empty = false;
  @override
  Stream<StatsContext> watchContext() async* {
    yield data;
    yield* changes.stream;
  }

  @override
  Future<Result<StatsContext>> refreshContext() async => Success(data);
  @override
  Future<Result<List<List<StatsBucket>>>> load(List<StatsQuery> queries) async {
    requests.add(queries);
    if (hold) {
      final completer = Completer<Result<List<List<StatsBucket>>>>();
      pending.add(completer);
      return completer.future;
    }
    if (fail) return const Failure(StorageUnavailable(retryable: true));
    return Success(buckets(queries));
  }

  List<List<StatsBucket>> buckets(List<StatsQuery> queries, {int? value}) => [
    for (final query in queries)
      [
        for (
          var i = 0;
          i <
              switch (query.period) {
                StatsPeriod.daily => 24,
                StatsPeriod.weekly => 7,
                StatsPeriod.monthly => DateTime.utc(
                  query.anchor.year,
                  query.anchor.month + 1,
                  0,
                ).day,
                StatsPeriod.yearly => 12,
              };
          i++
        )
          StatsBucket(
            start: boundary(query, i),
            end: boundary(query, i + 1),
            value:
                value ??
                (empty
                    ? 0
                    : (i % 5 + 1) *
                          (query.metric == StatsMetric.questTime
                              ? 60000
                              : 1000000)),
          ),
      ],
  ];
  DateTime boundary(StatsQuery query, int index) {
    final start = periodStart(query.period, query.anchor);
    return switch (query.period) {
      StatsPeriod.daily => start.add(Duration(hours: index)),
      StatsPeriod.weekly ||
      StatsPeriod.monthly => start.add(Duration(days: index)),
      StatsPeriod.yearly => DateTime.utc(start.year, index + 1),
    };
  }
}

Future<void> show(
  WidgetTester tester,
  FakeStatsSource source, {
  GlobalKey? key,
}) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MinutroveApp(
        home: Scaffold(body: StatsScreen(source: source)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> reveal(
  WidgetTester tester,
  Finder finder, {
  double delta = 300,
}) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      delta,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('stats-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 100,
    );
  }
  await tester.ensureVisible(
    finder.evaluate().length > 1 ? finder.last : finder,
  );
  await tester.pumpAndSettle();
}

Future<void> tapText(WidgetTester tester, String text) async {
  await reveal(tester, find.text(text));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Future<void> filters(WidgetTester tester) async {
  final button = find.textContaining('Filters:');
  await reveal(tester, button, delta: -500);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> chooseCategory(
  WidgetTester tester,
  String current,
  String next,
) async {
  await tapText(tester, current);
  if (find.text(next).evaluate().isEmpty) {
    await tester.enterText(
      find.widgetWithText(TextField, 'Search items'),
      next,
    );
    await tester.pumpAndSettle();
  }
  await tapText(tester, next);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('Nunito Sans')
      ..addFont(rootBundle.load('assets/fonts/NunitoSans.ttf'));
    await font.load();
    final material = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await material.load();
  });
  late FakeStatsSource source;
  setUp(() => source = FakeStatsSource());
  tearDown(() => source.changes.close());

  test('formatting retains large integer currency precision and units', () {
    expect(
      statsValue(
        BigInt.parse('9223372036854775807'),
        StatsMetric.coinsEarned,
        null,
      ),
      '9,223,372,036,854.775807',
    );
    expect(statsValue(BigInt.from(1), StatsMetric.questTime, null), '<0.001');
    expect(statsValue(BigInt.from(90000), StatsMetric.questTime, null), '1.5');
    expect(
      statsValue(
        BigInt.from(1234),
        StatsMetric.budgetSpent,
        BudgetCurrency.fromMetadata('USD', f.metadata),
      ),
      '12.34',
    );
    expect(
      statsValue(
        BigInt.from(1234),
        StatsMetric.budgetSpent,
        BudgetCurrency.fromMetadata('JPY', f.metadata),
      ),
      '1,234',
    );
    expect(
      shiftPeriod(StatsPeriod.monthly, DayKey(2024, 1, 31), 1),
      DayKey(2024, 2, 1),
    );
    expect(
      shiftPeriod(StatsPeriod.yearly, DayKey(2024, 2, 29), 1),
      DayKey(2025, 1, 1),
    );
    expect(shiftPeriod(StatsPeriod.daily, DayKey(1, 1, 1), -1), isNull);
    expect(shiftPeriod(StatsPeriod.yearly, DayKey(9999, 1, 1), 1), isNull);
  });

  testWidgets('all four periods, independent navigation, reset and date jump', (
    tester,
  ) async {
    await show(tester, source);
    expect(source.requests.single.map((q) => q.period), StatsPeriod.values);
    await tapText(tester, 'Choose monthly date');
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tapText(tester, 'Cancel');
    final monthly = find.byKey(const ValueKey('chart-monthly'));
    final previous = find.descendant(of: monthly, matching: find.text('‹'));
    await reveal(tester, previous);
    await tester.tap(previous);
    await tester.pumpAndSettle();
    expect(source.requests.last[2].anchor, DayKey(2026, 8, 1));
    expect(source.requests.last[0].anchor, DayKey(2026, 9, 6));
    expect(find.text('Monthly · Aug 2026'), findsOneWidget);
    await reveal(
      tester,
      find.descendant(of: monthly, matching: find.text('Current')),
    );
    await tester.tap(
      find.descendant(of: monthly, matching: find.text('Current')),
    );
    await tester.pumpAndSettle();
    expect(source.requests.last[2].anchor, DayKey(2026, 9, 6));
    await tapText(tester, 'Choose yearly date');
    // Enter a date directly rather than stepping through years of history.
    await tester.tap(find.byTooltip('Switch to input'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '02/29/2024');
    await tapText(tester, 'OK');
    expect(source.requests.last[3].anchor, DayKey(2024, 2, 29));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'filters apply consistently, disable incompatibility, include archives, cancel safely',
    (tester) async {
      await show(tester, source);
      await filters(tester);
      await chooseCategory(tester, 'All', 'Awards');
      expect(find.text('Choose Quests or All for this measure.'), findsWidgets);
      final disabled = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Selected: Award minutes used').first,
      );
      expect(disabled.onPressed, isNotNull);
      await tapText(tester, 'Budget spent');
      await tapText(tester, 'Apply filters');
      expect(
        source.requests.last.every(
          (q) =>
              q.category == StatsCategory.awards &&
              q.metric == StatsMetric.budgetSpent &&
              q.budgetCurrency?.code == 'USD',
        ),
        isTrue,
      );
      await filters(tester);
      await chooseCategory(tester, 'Awards', 'Old Focus (archived)');
      await tapText(tester, 'Apply filters');
      expect(
        source.requests.last.every(
          (q) =>
              q.itemId == ItemId(f.uuid(2)) &&
              q.metric == StatsMetric.questTime,
        ),
        isTrue,
      );
      final count = source.requests.length;
      await filters(tester);
      await tapText(tester, 'Coins earned');
      await tapText(tester, 'Cancel');
      expect(source.requests.length, count);
      await tapText(tester, 'Lines');
      expect(source.requests.length, count);
      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<StatsPlotPainter>();
      expect(painters.every((p) => p.graph == StatsGraph.lines), isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('currency filters never combine USD and JPY', (tester) async {
    final yen = Item(
      id: ItemId(f.uuid(8)),
      revision: Revision(1),
      name: 'Tea',
      iconKey: 'gamepad',
      colorArgb: 0xff7654a5,
      groupId: null,
      order: 8,
      archived: true,
      configuration: AwardConfiguration(
        packName: 'Tea',
        price: f.amounts(100),
        budgetGrant: BudgetAmount(
          BudgetCurrency.fromMetadata('JPY', f.metadata),
          1000,
        ),
      ),
    );
    source.data = StatsContext(
      items: [...source.data.items, yen],
      today: source.data.today,
      zone: source.data.zone,
    );
    final key = GlobalKey();
    await show(tester, source, key: key);
    await filters(tester);
    await tapText(tester, 'Budget spent');
    await tapText(tester, 'USD');
    await tapText(tester, 'Apply filters');
    expect(
      source.requests.last.every((q) => q.budgetCurrency?.code == 'USD'),
      isTrue,
    );
    await capture(tester, key, 'stats-budget-usd');
    await filters(tester);
    await tapText(tester, 'JPY');
    await tapText(tester, 'Apply filters');
    expect(
      source.requests.last.every((q) => q.budgetCurrency?.code == 'JPY'),
      isTrue,
    );
    expect(find.textContaining('USD · Budget spent'), findsNothing);
    expect(find.textContaining('JPY · Budget spent'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'search finds archived items in a large catalog without building every row',
    (tester) async {
      source.data = StatsContext(
        items: List.generate(
          5000,
          (i) => item(id: i + 100, name: 'Past Quest $i', archived: true),
        ),
        today: source.data.today,
        zone: f.zone,
      );
      await show(tester, source);
      await filters(tester);
      await tapText(tester, 'All');
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      await tester.enterText(
        find.widgetWithText(TextField, 'Search items'),
        'Past Quest 4999',
      );
      await tester.pumpAndSettle();
      await tapText(tester, 'Past Quest 4999 (archived)');
      await tapText(tester, 'Apply filters');
      expect(
        source.requests.last.every((q) => q.itemId == ItemId(f.uuid(5099))),
        isTrue,
      );
      expect(source.requests.last.map((q) => q.period), StatsPeriod.values);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a late response never replaces a newer filter snapshot', (
    tester,
  ) async {
    await show(tester, source);
    source.hold = true;
    source.changes.add(source.data);
    await tester.pump();
    source.changes.add(source.data);
    await tester.pump();
    expect(source.pending.length, 2);
    source.pending.last.complete(
      Success(source.buckets(source.requests.last, value: 60000)),
    );
    await tester.pumpAndSettle();
    expect(find.text('24 min · Quest minutes'), findsOneWidget);
    source.pending.first.complete(
      Success(source.buckets(source.requests.first, value: 120000)),
    );
    await tester.pumpAndSettle();
    expect(find.text('24 min · Quest minutes'), findsOneWidget);
    expect(find.text('48 min · Quest minutes'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('storage failure is distinct from zero and Retry recovers', (
    tester,
  ) async {
    source.fail = true;
    await show(tester, source);
    expect(find.textContaining('Could not read activity'), findsOneWidget);
    expect(find.textContaining('No activity'), findsNothing);
    source.fail = false;
    source.empty = true;
    await tapText(tester, 'Retry');
    expect(find.text('0 min · Quest minutes'), findsWidgets);
    expect(find.textContaining('Missing buckets'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'day changes advance current periods but preserve browsed history',
    (tester) async {
      await show(tester, source);
      final previous = find.descendant(
        of: find.byKey(const ValueKey('chart-daily')),
        matching: find.text('‹'),
      );
      await reveal(tester, previous);
      await tester.tap(previous);
      await tester.pumpAndSettle();
      source.data = StatsContext(
        items: source.data.items,
        today: DayKey(2026, 9, 7),
        zone: f.zone,
      );
      source.changes.add(source.data);
      await tester.pumpAndSettle();
      expect(source.requests.last[0].anchor, DayKey(2026, 9, 5));
      expect(source.requests.last[1].anchor, DayKey(2026, 9, 7));
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final (size, scale) in [
    (const Size(390, 844), 1.0),
    (const Size(320, 568), 2.0),
  ]) {
    testWidgets(
      'all charts and numeric summaries usable at $size with text $scale',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final semantics = tester.ensureSemantics();
        final key = GlobalKey();
        await show(tester, source, key: key);
        await capture(tester, key, 'stats-${size.width.toInt()}');
        await reveal(tester, find.byKey(const ValueKey('chart-daily')));
        await capture(tester, key, 'stats-daily-${size.width.toInt()}');
        await filters(tester);
        await tapText(tester, 'Lines');
        await tapText(tester, 'Apply filters');
        await reveal(tester, find.byKey(const ValueKey('chart-daily')));
        await capture(tester, key, 'stats-lines-${size.width.toInt()}');
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        for (final period in StatsPeriod.values) {
          final card = find.byKey(ValueKey('chart-${period.name}'));
          await reveal(
            tester,
            find.descendant(of: card, matching: find.text('View values')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(of: card, matching: find.text('View values')),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            find.descendant(of: card, matching: find.textContaining(': ')),
            findsWidgets,
          );
        }
        await filters(tester);
        await tapText(tester, 'Apply filters');
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
