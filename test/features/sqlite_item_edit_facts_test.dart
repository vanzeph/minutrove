import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/items/items.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/item_repository_test.dart' show TestClock, TestCalendar;
import '../data/support.dart' as f;

void main() {
  sqfliteFfiInit();
  test(
    'editing facts read active/history and committed goal dates from SQLite',
    () async {
      final dir = await Directory.systemTemp.createTemp('minutrove-editor-');
      final store = f.success(
        await SqliteStore.open(
          path: '${dir.path}/test.db',
          factory: databaseFactoryFfi,
          currencies: f.metadata,
          initialSettings: f.settings,
        ),
      );
      addTearDown(() async {
        await store.close();
        await dir.delete(recursive: true);
      });
      final repo = SqliteItemRepository(
        store: store,
        clock: TestClock(),
        calendar: TestCalendar(),
      );
      var serial = 20;
      final item = f.success(
        await repo.saveItem(
          operationId: OperationId(f.uuid(serial++)),
          item: f.quest(),
          expectedRevision: null,
        ),
      );
      final reader = sqliteItemEditFacts(store);
      var facts = f.success(await reader(item.id));
      expect(facts.hasHistory, false);
      expect(facts.active, false);
      expect(goalDate(facts.latestGoal!), '2026-01-15 (Etc/UTC)');
      f.success(
        await store.write((tx) async {
          await tx.putSession(f.session(item));
          return true;
        }),
      );
      facts = f.success(await reader(item.id));
      expect(facts.hasHistory, true);
      expect(facts.active, true);
      final draft = ItemDraft(id: item.id, item: item)
        ..goalDuration = '2'
        ..goalUnit = TimeUnit.minutes;
      f.success(
        await repo.saveItem(
          operationId: OperationId(f.uuid(serial++)),
          item: draft.build(f.metadata),
          expectedRevision: item.revision,
        ),
      );
      facts = f.success(await reader(item.id));
      expect(goalDate(facts.latestGoal!), '2026-01-16 (Etc/UTC)');
      final invalid = ItemDraft(id: item.id, item: item)..coins = 'NaN';
      expect(() => invalid.build(f.metadata), throwsA(isA<InvalidInput>()));
      expect(f.success(await repo.getItem(item.id))!.revision.value, 2);
    },
  );
}
