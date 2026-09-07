import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/home/home.dart';
import 'package:minutrove/features/stats/stats.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/support.dart' as f;
import 'home_shell_test.dart' show HomeFixture, flush, item;

void main() {
  sqfliteFfiInit();
  late HomeFixture fixture;
  late SqliteStatsSource source;
  setUp(() async {
    fixture = HomeFixture();
    await fixture.open();
    source = SqliteStatsSource(
      store: fixture.store,
      calendar: IanaReportingCalendar(),
      utcNow: () => fixture.clock.utc,
    );
  });
  tearDown(() async {
    await fixture.close();
  });

  test(
    'real session totals agree in four periods and survive archive',
    () async {
      var quest = await fixture.save(item(id: 1, name: 'Focus'));
      final started = f.success(
        await fixture.sessions.startSession(
          operationId: fixture.op(),
          itemId: quest.id,
          expectedItemRevision: quest.revision,
          conflictChoice: SessionConflictChoice.cancel,
        ),
      );
      fixture.clock.advance(30000);
      f.success(
        await fixture.sessions.endSession(
          operationId: fixture.op(),
          sessionId: started.session.id,
          expectedRevision: started.session.revision,
        ),
      );
      quest = f.success(
        await fixture.items.archiveItem(
          operationId: fixture.op(),
          itemId: quest.id,
          expectedRevision: quest.revision,
        ),
      );
      final data = f.success(await source.refreshContext());
      expect(data.items.single.archived, isTrue);
      final selection = StatsSelection(
        category: StatsCategory.item,
        itemId: quest.id,
      );
      final before = await fixture.operationCount();
      final charts = f.success(
        await source.load([
          for (final period in StatsPeriod.values)
            selection.query(period, data.today),
        ]),
      );
      expect(charts.map((b) => b.length), [24, 7, 31, 12]);
      for (final chart in charts) {
        expect(chart.fold(0, (total, bucket) => total + bucket.value), 30000);
      }
      expect(await fixture.operationCount(), before);
      final earned = f.success(
        await source.load([
          for (final period in StatsPeriod.values)
            StatsQuery(
              period: period,
              anchor: data.today,
              category: StatsCategory.item,
              itemId: quest.id,
              metric: StatsMetric.coinsEarned,
            ),
        ]),
      );
      final wallet = f.success(await fixture.store.read((r) => r.wallet()));
      expect(
        earned.map((b) => b.fold(0, (n, b) => n + b.value)),
        everyElement(wallet.balances.coins.units),
      );
    },
  );

  test('context uses reporting timezone and invalid currency/items fail without effects', () async {
    final award = await fixture.save(
      item(id: 3, name: 'Coffee', award: true, time: false, budget: true),
    );
    final context = f.success(await source.refreshContext());
    expect(context.currencies.map((c) => c.code), ['USD']);
    final invalid = await source.load([
      StatsQuery(
        period: StatsPeriod.daily,
        anchor: context.today,
        category: StatsCategory.item,
        itemId: award.id,
        metric: StatsMetric.budgetSpent,
        budgetCurrency: BudgetCurrency.fromMetadata('JPY', f.metadata),
      ),
    ]);
    expect(invalid, isA<Failure<List<List<StatsBucket>>>>());
    final settings = SqliteSettingsRepository(
      store: fixture.store,
      clock: fixture.clock,
      calendar: IanaReportingCalendar(),
    );
    final old = f.success(await settings.getSettings());
    f.success(
      await settings.saveSettings(
        operationId: fixture.op(),
        expectedRevision: old.revision,
        reportingZone: ReportingZone('Pacific/Kiritimati'),
      ),
    );
    fixture.clock.utc = DateTime.utc(2026, 1, 15, 12);
    expect(f.success(await source.refreshContext()).today, DayKey(2026, 1, 16));
    await fixture.close();
    expect(await source.refreshContext(), isA<Failure<StatsContext>>());
  });

  testWidgets(
    'HomeShell shares store, wallet and active session while viewing Stats',
    (tester) async {
      await tester.runAsync(() async {
        final quest = await fixture.save(item(id: 1, name: 'Focus'));
        f.success(
          await fixture.sessions.startSession(
            operationId: fixture.op(),
            itemId: quest.id,
            expectedItemRevision: quest.revision,
            conflictChoice: SessionConflictChoice.cancel,
          ),
        );
      });
      final before = await tester.runAsync(fixture.operationCount);
      await tester.pumpWidget(
        MinutroveApp(
          home: HomeShell(
            watchHome: () => watchSqliteHome(fixture.store),
            editing: fixture.editing,
            sessions: fixture.sessions,
            clock: fixture.clock,
            routes: HomeRoutes(
              shop: (_) => const Text('Shop'),
              stats: (_) => StatsScreen(source: source),
              openSession: (_, _, _) async {},
              openExpense: (_, _, _, _) async {},
            ),
          ),
        ),
      );
      await flush(tester);
      await tester.tap(find.text('Stats'));
      await flush(tester);
      expect(find.text('Your progress'), findsOneWidget);
      expect(find.text('Running · 1:00'), findsOneWidget);
      expect(find.text('0 min · Quest minutes'), findsWidgets);
      final after = await tester.runAsync(fixture.operationCount);
      expect(
        after,
        before,
        reason: 'Viewing stats must not settle or stop a running session.',
      );
      await tester.tap(find.text('Home'));
      await flush(tester);
      expect(find.text('Running · 1:00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
      await tester.runAsync(fixture.close);
    },
  );
}
