import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/session_fixtures.dart';
import 'fault_database.dart';
import 'support.dart' as f;

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late SqliteStore store;
  late SessionClock clock;
  late SqliteItemRepository items;
  late SqliteSessionRepository sessions;
  late SqliteEconomyRepository economy;
  var serial = 1000;
  OperationId op() => OperationId(f.uuid(serial++));
  String path() => '${directory.path}/data.sqlite';
  const codec = BackupCodec();
  Future<Result<BackupFile>> export({
    BackupCodec codec = codec,
    Clock? sample,
  }) => SqliteBackupExporter(
    store: store,
    clock: sample ?? clock,
    codec: codec,
  ).exportBackup(operationId: op());
  Future<SessionMutation> start(Item item) async => f.success(
    await sessions.startSession(
      operationId: op(),
      itemId: item.id,
      expectedItemRevision: item.revision,
      conflictChoice: SessionConflictChoice.cancel,
    ),
  );
  Future<void> end(Session s) async => f.success(
    await sessions.endSession(
      operationId: op(),
      sessionId: s.id,
      expectedRevision: s.revision,
    ),
  );
  Future<Item> save(Item item) async => f.success(
    await items.saveItem(operationId: op(), item: item, expectedRevision: null),
  );

  setUp(() async {
    serial = 1000;
    directory = await Directory.systemTemp.createTemp('minutrove-export-');
    clock = SessionClock();
    store = f.success(
      await SqliteStore.open(
        path: path(),
        factory: databaseFactoryFfi,
        currencies: f.metadata,
        initialSettings: f.settings,
      ),
    );
    final calendar = SessionCalendar();
    items = SqliteItemRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
    sessions = SqliteSessionRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
    economy = SqliteEconomyRepository(
      store: store,
      clock: clock,
      calendar: calendar,
    );
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('empty snapshot includes exact singletons, counts and independent integrity', () async {
    final before = await dump(path());
    final file = f.success(await export());
    final decoded = codec.decode(file);
    expect(decoded.preview.recordCounts['wallet'], 1);
    expect(decoded.preview.recordCounts['settings'], 1);
    expect(decoded.preview.recordCounts['operations'], 0);
    expect(decoded.snapshot.sourceSchemaVersion.value, 2);
    expect(decoded.snapshot.currencyMetadataVersion, f.metadata.version);
    expect(codec.encode(decoded.snapshot).bytes, file.bytes);
    expect(decoded.preview.sha256, sha256.convert(file.bytes).toString());
    final root = jsonDecode(utf8.decode(file.bytes)) as Map<String, dynamic>;
    // A separate encoder confirms which exact UTF-8 bytes are covered.
    final payload = utf8.encode(jsonEncode(root['payload']));
    expect(root['integrity']['sha256'], sha256.convert(payload).toString());
    expect(root['integrity']['payloadBytes'], payload.length);
    expect(await dump(path()), before);
    expect(() => file.bytes[0] = 0, throwsUnsupportedError);
    expect(
      () => decoded.snapshot.records['settings']!.clear(),
      throwsUnsupportedError,
    );
  });

  test('earn, goal, purchase, expense, time use and edits preserve complete history', () async {
    final g = f.success(
      await items.saveGroup(
        operationId: op(),
        group: f.group(),
        expectedRevision: null,
      ),
    );
    final q = await save(f.quest(groupId: g.id, name: 'Synthetic 学习 🎮'));
    final a = await save(f.award());
    final completed = await start(q);
    clock.advance(60000);
    f.success(
      await sessions.reconcileSession(
        operationId: op(),
        sessionId: completed.session.id,
      ),
    );
    final split = await start(q);
    clock.advance(7);
    await end(split.session);
    final bought = f.success(
      await economy.redeemAward(
        operationId: op(),
        awardId: a.id,
        expectedRevision: a.revision,
        quantity: PurchaseQuantity(2),
      ),
    );
    f.success(
      await economy.recordExpense(
        operationId: op(),
        awardId: a.id,
        expectedBalanceRevision: bought.awards.single.revision,
        expense: BudgetAmount(
          BudgetCurrency.fromMetadata('USD', f.metadata),
          1250,
        ),
        conflictChoice: SessionConflictChoice.cancel,
      ),
    );
    final used = await start(a);
    clock.advance(1234);
    await end(used.session);
    final archived = f.success(
      await items.archiveItem(
        operationId: op(),
        itemId: q.id,
        expectedRevision: q.revision,
      ),
    );
    f.success(
      await items.removeGroup(
        operationId: op(),
        groupId: g.id,
        expectedRevision: g.revision,
      ),
    );
    final before = await dump(path());
    final file = f.success(await export());
    final snapshot = codec.decode(file).snapshot;
    final rows = snapshot.records;
    expect(rows['groups'], isEmpty);
    expect(rows['items']!.first['archived'], true);
    expect(rows['items']!.first['group'], null);
    expect(
      rows['items']!.first['revision'],
      '${archived.revision.next().value}',
    );
    expect(rows['itemRevisions']!.length, 4);
    expect((rows['itemRevisions']!.first['item'] as Map)['group'], g.id.value);
    expect(rows['sessions']!.length, 3);
    expect(
      rows['sessions']!.map((r) => r['status']),
      containsAll(['ended', 'completed']),
    );
    expect(rows['goalRevisions']!.length, 1);
    expect(rows['achievements']!.length, 1);
    expect(rows['accrualRemainders']!.first['value'], isNot('0'));
    final current = f.success(
      await store.read(
        (r) async => (await r.wallet(), await r.awards(), await r.ledger()),
      ),
    );
    final wallet = rows['wallet']!.single['balances'] as Map;
    expect(wallet['coins'], '${current.$1.balances.coins.units}');
    expect(
      rows['awardBalances']!.single['time'],
      '${current.$2.single.time!.value}',
    );
    expect((rows['awardBalances']!.single['budget'] as Map)['minor'], '750');
    expect(rows['ledger']!.length, current.$3.length);
    final raw = jsonDecode(before) as Map<String, dynamic>;
    expect(rows['operations']!.length, (raw['operations'] as List).length);
    for (final stored in raw['operations'] as List) {
      final portable = rows['operations']!.singleWhere(
        (r) => r['id'] == stored['id'],
      );
      expect(portable['fingerprint'], stored['request_fingerprint']);
    }
    expect(codec.decode(codec.encode(snapshot)).snapshot.records, rows);
    expect(f.success(await export()).bytes, file.bytes);
    expect(await dump(path()), before);
    final json = utf8.decode(file.bytes);
    for (final private in [
      'session-test',
      'monotonic',
      'deadline',
      'boot',
      'intent',
      'handled',
      directory.path,
    ]) {
      expect(
        json.contains(private),
        false,
        reason: 'Excluded runtime field: $private',
      );
    }
    expect(
      rows['operations']!.any(
        (r) => (r['result'] as Map)['type'] == 'sessionMutation',
      ),
      true,
    );
  });

  for (final paused in [false, true]) {
    test(
      '${paused ? 'paused' : 'running'} export rejects without clock, settlement or notification effects',
      () async {
        final q = await save(f.quest());
        var s = await start(q);
        if (paused) {
          s = f.success(
            await sessions.pauseSession(
              operationId: op(),
              sessionId: s.session.id,
              expectedRevision: s.session.revision,
            ),
          );
        }
        clock.advance(120000);
        clock.unavailable = true;
        final before = await dump(path());
        expect(
          await export(),
          isA<Failure<BackupFile>>().having(
            (r) => r.error,
            'error',
            isA<ActiveSessionConflict>(),
          ),
        );
        expect(await dump(path()), before);
        expect(
          f.success(await store.read((r) => r.activeSession()))!.id,
          s.session.id,
        );
      },
    );
  }

  test(
    'export and competing mutation occupy a single consistent queue slot',
    () async {
      final sampled = Completer<void>();
      final release = Completer<ClockReading>();
      final reading = _AsyncClock(() {
        sampled.complete();
        return release.future;
      });
      final pending = export(sample: reading);
      await sampled.future;
      var mutated = false;
      final later = items
          .saveGroup(
            operationId: op(),
            group: f.group(),
            expectedRevision: null,
          )
          .then((r) {
            mutated = true;
            return f.success(r);
          });
      await Future<void>.delayed(Duration.zero);
      expect(mutated, false);
      release.complete(clock.now());
      expect(
        codec.decode(f.success(await pending)).snapshot.records['groups'],
        isEmpty,
      );
      await later;
      expect(
        codec
            .decode(f.success(await export()))
            .snapshot
            .records['groups']!
            .length,
        1,
      );
    },
  );

  test(
    'record/count/byte limits fail closed and retain the original store',
    () async {
      await save(f.quest(name: 'Synthetic ' * 100));
      final before = await dump(path());
      for (final limits in [
        const BackupLimits(maxRecords: 2),
        const BackupLimits(maxRecordBytes: 100),
        const BackupLimits(maxFileBytes: 100),
      ]) {
        expect(
          await export(codec: BackupCodec(limits: limits)),
          isA<Failure<BackupFile>>().having(
            (r) => r.error,
            'error',
            isA<InvalidBackup>(),
          ),
        );
        expect(await dump(path()), before);
      }
    },
  );

  test(
    'preflight includes history past a page and every disabled goal revision',
    () async {
      final q = await save(f.quest());
      f.success(
        await store.write((tx) async {
          for (var i = 2; i <= 260; i++) {
            await tx.insertGoal(
              DailyGoalRevision(
                questId: q.id,
                revision: Revision(i),
                effectiveFrom: f.event.day,
                zone: f.zone,
                goal: null,
              ),
            );
          }
        }),
      );
      final records = codec.decode(f.success(await export())).snapshot.records;
      expect(records['goalRevisions']!.length, 260);
      expect(records['goalRevisions']!.last['revision'], '260');
      expect(records['goalRevisions']!.last['goal'], null);
    },
  );

  test('clock/read availability failures return typed errors without changing data', () async {
    final before = await dump(path());
    clock.unavailable = true;
    expect(
      await export(),
      isA<Failure<BackupFile>>().having(
        (r) => r.error,
        'error',
        isA<StorageUnavailable>(),
      ),
    );
    expect(await dump(path()), before);
    await store.close();
    expect(
      await export(),
      isA<Failure<BackupFile>>().having(
        (r) => r.error,
        'error',
        isA<StorageUnavailable>(),
      ),
    );
  });
}

final class _AsyncClock implements Clock {
  const _AsyncClock(this.sample);
  final Future<ClockReading> Function() sample;
  @override
  Future<ClockReading> now() => sample();
}
