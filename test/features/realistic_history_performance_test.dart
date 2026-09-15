import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app_startup.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/home/home.dart';
import 'package:minutrove/features/stats/stats.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../app_startup_test.dart' show StartupFixture, pumpApp;
import '../features/home_shell_test.dart' show flush;
import '../data/support.dart' as f;

/// Measured behavior over a realistic multi-year synthetic history: cold
/// composition startup, the four-period Stats aggregation, and Home/Stats
/// scrolling. Timings print with the expanded reporter and use loose
/// regression bounds — they are host measurements under `flutter test`,
/// not physical-device frame-rate claims.
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

  late StartupFixture fixture;
  setUp(() async {
    fixture = StartupFixture();
    await fixture.create();
  });
  tearDown(() async {
    await fixture.destroy();
  });

  // Personal-scale catalog: four groups, twelve Quests, three Awards.
  Future<List<Item>> seedCatalog(AppComposition composition) async {
    const names = ['Body', 'Mind', 'Craft', 'People'];
    final groups = <Group>[];
    var serial = 2000;
    OperationId op() => OperationId(f.uuid(serial++));
    for (var n = 0; n < names.length; n++) {
      final saved = await composition.items.saveGroup(
        operationId: op(),
        group: f.group(n: 101 + n, name: names[n]),
        expectedRevision: null,
      );
      groups.add((saved as Success<Group>).value);
    }
    final items = <Item>[];
    for (var n = 0; n < 12; n++) {
      final quest = f.quest(
        n: 10 + n,
        name: 'Quest $n',
        groupId: groups[n % groups.length].id,
      );
      final saved = await composition.items.saveItem(
        operationId: op(),
        item: quest,
        expectedRevision: null,
      );
      items.add((saved as Success<Item>).value);
    }
    for (var n = 0; n < 3; n++) {
      final saved = await composition.items.saveItem(
        operationId: op(),
        item: f.award(n: 40 + n),
        expectedRevision: null,
      );
      items.add((saved as Success<Item>).value);
    }
    return items;
  }

  /// Five years of settled quest-time postings across every day, sized like
  /// real usage (several sessions per day) plus one dense day. Quest time
  /// postings are excluded from wallet projections by design, so the file
  /// stays internally consistent for reopen validation.
  Future<int> seedMultiYearLedger(String path, List<Item> quests) async {
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    var rows = 0;
    await db.transaction((tx) async {
      await tx.rawInsert(
        '''INSERT INTO operations
        (id,kind,request_fingerprint,result,committed_utc,committed_day,
         committed_zone,committed_offset)
        VALUES(?,?,?,?,?,?,?,?)''',
        [
          f.uuid(9000),
          'sessionEnd',
          'synthetic-history',
          'synthetic',
          DateTime.utc(2026, 9, 14).millisecondsSinceEpoch,
          '2026-09-14',
          'Etc/UTC',
          0,
        ],
      );
      final batch = tx.batch();
      const start = Duration(days: 1826); // ≈ 2021-09-14 .. 2026-09-14
      final base = DateTime.utc(2026, 9, 14);
      for (var day = 0; day < start.inDays; day++) {
        final date = base.subtract(Duration(days: day));
        final text =
            '${date.year.toString().padLeft(4, '0')}-'
            '${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')}';
        for (var session = 0; session < 3; session++) {
          final item = quests[(day + session) % quests.length];
          batch.rawInsert(
            '''INSERT INTO ledger_entries
            (id,operation_id,item_id,item_revision,dimension,delta,
             assigned_utc,assigned_day,assigned_zone,assigned_offset)
            VALUES(?,?,?,?,?,?,?,?,?,?)''',
            [
              f.uuid(100000 + rows),
              f.uuid(9000),
              item.id.value,
              item.revision.value,
              'time',
              1500000 + ((day * 7 + session) % 40) * 60000,
              date.millisecondsSinceEpoch + session * 3600000,
              text,
              'Etc/UTC',
              0,
            ],
          );
          rows++;
        }
      }
      await batch.commit(noResult: true);
    });
    await db.close();
    return rows;
  }

  testWidgets('multi-year history stays fast to open, query and scroll', (
    tester,
  ) async {
    final items = await tester.runAsync<List<Item>>(() async {
      final opened = await fixture.open();
      expect(opened, isA<Success<(AppComposition, bool)>>());
      final composition = (opened as Success<(AppComposition, bool)>).value.$1;
      final catalog = await seedCatalog(composition);
      final quests = catalog.where((i) => i.type == ItemType.quest).toList();
      final rows = await seedMultiYearLedger(fixture.databasePath, quests);
      // ignore: avoid_print
      print(
        'perf: seeded $rows ledger rows over 5 years, '
        '${catalog.length} items, ${quests.length} quests',
      );
      await composition.close();
      fixture.composition = null;
      return catalog;
    });
    expect(items, hasLength(15));

    // Cold startup over the populated file: reopen (full validation),
    // lifecycle start, first Home read and the four-period Stats aggregation.
    final startupWatch = Stopwatch()..start();
    final statsWatch = Stopwatch();
    final warmWatch = Stopwatch();
    var seededRowsMessage = '';
    await tester.runAsync(() async {
      final reopened = await fixture.open();
      final live = (reopened as Success<(AppComposition, bool)>).value.$1;
      await live.start();
      final home = await watchSqliteHome(live.store).first;
      expect(home.items, hasLength(15));
      expect(home.groups, hasLength(4));
      startupWatch.stop();
      // ignore: avoid_print
      print(
        'perf: populated startup (open + validate + start + first HomeData) '
        '= ${startupWatch.elapsedMilliseconds} ms',
      );

      statsWatch.start();
      final context = await live.statsSource.refreshContext();
      final today = (context as Success<StatsContext>).value.today;
      const selection = StatsSelection();
      final charts = await live.statsSource.load([
        for (final period in StatsPeriod.values) selection.query(period, today),
      ]);
      statsWatch.stop();
      final loaded = (charts as Success<List<List<StatsBucket>>>).value;
      expect(loaded, hasLength(4));
      expect(loaded.last, hasLength(12)); // yearly chart has twelve months
      seededRowsMessage =
          'perf: four-period Stats aggregation (daily/weekly/monthly/yearly, '
          'all items) = ${statsWatch.elapsedMilliseconds} ms';

      warmWatch.start();
      await live.statsSource.load([
        for (final period in StatsPeriod.values) selection.query(period, today),
      ]);
      warmWatch.stop();
      await live.close();
      fixture.composition = null;
    });
    // ignore: avoid_print
    print(seededRowsMessage);
    // ignore: avoid_print
    print(
      'perf: warm repeat aggregation = ${warmWatch.elapsedMilliseconds} ms',
    );

    // The real startup widget over the same file: time to first Home frame.
    final uiWatch = Stopwatch()..start();
    await pumpApp(tester, fixture);
    uiWatch.stop();
    // ignore: avoid_print
    print(
      'perf: MinutroveStartup to first Home frame (populated) = '
      '${uiWatch.elapsedMilliseconds} ms',
    );
    // The shell renders before the first HomeData emission lands.
    var tiles = 0;
    for (var attempt = 0; attempt < 100 && tiles == 0; attempt++) {
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 50));
      tiles = find
          .byWidgetPredicate(
            (widget) => widget is Text && widget.data!.startsWith('Quest '),
          )
          .evaluate()
          .length;
    }
    expect(tiles, greaterThan(0), reason: 'Seeded quests render on Home');
    expect(tester.takeException(), isNull);

    /// Wall-clock per scroll gesture including pumpAndSettle. The tester does
    /// not deliver engine FrameTiming samples under fake async, so this host
    /// wall measurement is the honest scrolling proxy.
    Future<Duration> wallPerGesture(
      String label,
      int gestures,
      Future<void> Function() scroll,
    ) async {
      final watch = Stopwatch()..start();
      await scroll();
      watch.stop();
      final per = Duration(milliseconds: watch.elapsedMilliseconds ~/ gestures);
      // ignore: avoid_print
      print(
        'perf: $label scrolling, $gestures gestures, wall '
        '${watch.elapsedMilliseconds} ms total, $per per gesture',
      );
      return per;
    }

    final homeList = find.descendant(
      of: find.byKey(const PageStorageKey('home-scroll')),
      matching: find.byType(Scrollable),
    );
    final homeFrame = await wallPerGesture('Home', 12, () async {
      for (var i = 0; i < 6; i++) {
        await tester.drag(homeList, const Offset(0, -400));
        await tester.pumpAndSettle();
      }
      for (var i = 0; i < 6; i++) {
        await tester.drag(homeList, const Offset(0, 400));
        await tester.pumpAndSettle();
      }
    });
    expect(
      homeFrame,
      lessThan(const Duration(milliseconds: 100)),
      reason: 'Home scrolling stays usable',
    );

    // Stats over five years of data renders all four charts and scrolls.
    // The indeterminate loading indicator never settles, so pump in bounded
    // steps until the yearly chart becomes visible instead of pumpAndSettle.
    await tester.tap(find.text('Stats'));
    for (
      var i = 0;
      i < 100 && find.byKey(const ValueKey('chart-yearly')).evaluate().isEmpty;
      i++
    ) {
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byKey(const ValueKey('chart-yearly')).evaluate().isEmpty) {
        await tester.drag(
          find
              .descendant(
                of: find.byKey(const PageStorageKey('stats-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
          const Offset(0, -400),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    expect(
      find.byKey(const ValueKey('chart-yearly')),
      findsOneWidget,
      reason: 'The yearly chart renders over the multi-year history',
    );
    final statsList = find
        .descendant(
          of: find.byKey(const PageStorageKey('stats-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    final statsFrame = await wallPerGesture('Stats', 12, () async {
      for (var i = 0; i < 4; i++) {
        await tester.drag(statsList, const Offset(0, -400));
        await tester.pump(const Duration(milliseconds: 100));
      }
      for (var i = 0; i < 8; i++) {
        await tester.drag(statsList, const Offset(0, 400));
        await tester.pump(const Duration(milliseconds: 100));
      }
    });
    expect(
      statsFrame,
      lessThan(const Duration(milliseconds: 100)),
      reason: 'Stats scrolling stays usable',
    );

    // Loose regression bounds for shared CI hosts; local prints above carry
    // the honest measured values.
    expect(startupWatch.elapsedMilliseconds, lessThan(20000));
    expect(statsWatch.elapsedMilliseconds, lessThan(20000));

    // Ending like the other startup-fixture widget tests in this repo:
    // unmount the tree and let tearDown destroy the temporary directory.
    // Closing the composition after the tree is unmounted deadlocks the
    // tester on this pinned SDK, so no explicit close happens here.
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
  });
}
