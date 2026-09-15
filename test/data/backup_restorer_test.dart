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
  late SessionClock clock;
  late SqliteBackupRestorer restorer;
  late SqliteItemRepository items;
  late SqliteSessionRepository sessions;
  late SqliteEconomyRepository economy;
  late RecordingScheduler scheduler;
  var serial = 1000;
  OperationId op() => OperationId(f.uuid(serial++));
  String path() => '${directory.path}/data.sqlite';
  const codec = BackupCodec();
  const productTables = {'operations', 'notification_intents'};

  Future<BackupFile> export() async => f.success(
    await SqliteBackupRepository(
      restorer: restorer,
      clock: clock,
    ).exportBackup(operationId: op()),
  );
  Future<BackupPreview> inspect(BackupFile file) async =>
      f.success(await restorer.inspectBackup(file));
  Future<Revision> liveSettingsRevision() async =>
      f.success(await restorer.store.read((r) => r.settings())).revision;
  Future<RestoreReceipt> restore(
    BackupFile file, {
    BackupPreview? preview,
    Revision? expectedSettingsRevision,
  }) async => f.success(
    await restorer.restoreBackup(
      operationId: op(),
      file: file,
      confirmation: RestoreConfirmation(
        preview: preview ?? await inspect(file),
        expectedSettingsRevision:
            expectedSettingsRevision ?? await liveSettingsRevision(),
      ),
    ),
  );

  void rebuildRepositories() {
    final calendar = SessionCalendar();
    items = SqliteItemRepository(
      store: restorer.store,
      clock: clock,
      calendar: calendar,
    );
    sessions = SqliteSessionRepository(
      store: restorer.store,
      clock: clock,
      calendar: calendar,
    );
    economy = SqliteEconomyRepository(
      store: restorer.store,
      clock: clock,
      calendar: calendar,
    );
  }

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

  /// Rich synthetic history: goals, achievements, remainders, purchases,
  /// expenses, award time use and split sessions, mirroring the exporter
  /// scenario.
  Future<(Item, Item)> populateSyntheticHistory() async {
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
    return (q, a);
  }

  Future<SqliteBackupRestorer> openRestorer(
    DatabaseFactory factory, {
    BackupCodec codec = codec,
  }) async => f.success(
    await SqliteBackupRestorer.open(
      path: path(),
      factory: factory,
      currencies: f.metadata,
      initialSettings: f.settings,
      clock: clock,
      calendar: SessionCalendar(),
      scheduler: scheduler,
      codec: codec,
    ),
  );

  setUp(() async {
    serial = 1000;
    directory = await Directory.systemTemp.createTemp('minutrove-restore-');
    clock = SessionClock();
    scheduler = RecordingScheduler();
    restorer = await openRestorer(databaseFactoryFfi);
    rebuildRepositories();
  });

  tearDown(() async {
    await restorer.close();
    await directory.delete(recursive: true);
  });

  Future<Map<String, dynamic>> dumpExcept(Set<String> except) async {
    final db = await databaseFactoryFfi.openDatabase(
      path(),
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
      );
      return {
        for (final table in tables)
          if (!except.contains(table['name']))
            table['name'] as String: await db.query(
              table['name'] as String,
              orderBy: 'rowid',
            ),
      };
    } finally {
      await db.close();
    }
  }

  Set<String> sideFileNames() =>
      Directory(directory.path)
          .listSync()
          .map((entry) => entry.uri.pathSegments.last)
          .toSet();

  test(
    'inspect validates in a temporary store and previews source date/counts',
    () async {
      await populateSyntheticHistory();
      final file = await export();
      final before = await dumpExcept(const {});
      final preview = await inspect(file);
      expect(preview.version.value, 1);
      expect(preview.createdUtc, clock.utc);
      expect(preview.sha256, sha256.convert(file.bytes).toString());
      expect(preview.recordCounts['sessions'], 3);
      expect(preview.recordCounts['operations'], greaterThan(5));
      expect(preview.recordCounts['wallet'], 1);
      expect(preview.recordCounts['settings'], 1);
      expect(await dumpExcept(const {}), before);
      expect(sideFileNames(), {'data.sqlite'});
      expect(
        f.success(await restorer.store.read((r) async => r.items())),
        isNotEmpty,
      );
    },
  );

  test(
    'restore replaces confirmed data, reopens and reports the receipt',
    () async {
      final (q, a) = await populateSyntheticHistory();
      final file = await export();
      final expectedRecords = codec.decode(file).snapshot.records;
      final expectedWallet = f.success(
        await restorer.store.read((r) => r.wallet()),
      );
      final expectedAchievements = f.success(
        await restorer.store.read((r) => r.achievements()),
      );
      final revision = await liveSettingsRevision();
      final preview = await inspect(file);

      // Diverging live data is the state the user confirmed to replace.
      await save(f.quest(n: 9, name: 'Target-only quest'));
      expect(f.success(await restorer.store.read((r) => r.items())).length, 3);

      final receipt = await restore(
        file,
        preview: preview,
        expectedSettingsRevision: revision,
      );
      expect(receipt.sourceSha256, preview.sha256);
      expect(receipt.schemaVersion.value, currentBackupSchemaVersion);
      expect(receipt.settings.revision, f.settings.revision);

      rebuildRepositories();
      final wallet = f.success(await restorer.store.read((r) => r.wallet()));
      expect(wallet.balances.coins.units, expectedWallet.balances.coins.units);
      expect(wallet.balances.gems.units, expectedWallet.balances.gems.units);
      final achievements = f.success(
        await restorer.store.read((r) => r.achievements()),
      );
      expect(achievements, hasLength(expectedAchievements.length));
      for (var i = 0; i < achievements.length; i++) {
        expect(achievements[i].questId, expectedAchievements[i].questId);
        expect(achievements[i].day, expectedAchievements[i].day);
        expect(
          achievements[i].bonus.coins.units,
          expectedAchievements[i].bonus.coins.units,
        );
        expect(
          achievements[i].bonus.gems.units,
          expectedAchievements[i].bonus.gems.units,
        );
      }
      expect(
        f.success(await restorer.store.read((r) => r.items())).map((i) => i.id),
        containsAll([q.id, a.id]),
      );
      expect(sideFileNames(), {'data.sqlite', 'data.sqlite.restore-safety'});
      expect(scheduler.calls.single.intents, isEmpty);
      expect(
        f.success(await restorer.store.read((r) => r.notificationIntents())),
        isEmpty,
      );
      // The restored database serves a fresh export with the same logical
      // records; only the durable restore operation joins the history.
      final reexported = codec.decode(await export()).snapshot.records;
      for (final name in backupCollections.where((n) => n != 'operations')) {
        expect(reexported[name], expectedRecords[name], reason: name);
      }
      expect(
        reexported['operations']!.length,
        expectedRecords['operations']!.length + 1,
      );
    },
  );

  test(
    'restoring twice reproduces the same state, with no timer or bonus replay',
    () async {
      await populateSyntheticHistory();
      final file = await export();
      await restore(file);
      rebuildRepositories();
      final firstRecords = codec.decode(await export()).snapshot.records;

      // Live diverges again between restores.
      await save(f.quest(n: 10, name: 'Between restores'));
      final second = await restore(file);
      expect(second.sourceSha256, sha256.convert(file.bytes).toString());
      rebuildRepositories();
      final secondRecords = codec.decode(await export()).snapshot.records;
      for (final name in backupCollections.where((n) => n != 'operations')) {
        expect(secondRecords[name], firstRecords[name], reason: name);
      }
      // Each restore appends exactly its own operation to the snapshot's
      // history; repeated restores never accumulate anything else.
      expect(
        secondRecords['operations']!.length,
        firstRecords['operations']!.length,
      );
      List<Map<String, Object?>> restoresOf(Map<String, Object?> records) =>
          (records['operations'] as List)
              .where((record) => (record as Map)['kind'] == 'restoreBackup')
              .cast<Map<String, Object?>>()
              .toList();
      expect(restoresOf(firstRecords), hasLength(1));
      expect(restoresOf(secondRecords), hasLength(1));
      expect(
        restoresOf(secondRecords).single['id'],
        isNot(restoresOf(firstRecords).single['id']),
      );
      expect(
        f.success(await restorer.store.read((r) => r.activeSession())),
        isNull,
      );
      expect(scheduler.calls, hasLength(2));
      expect(scheduler.calls.every((call) => call.intents.isEmpty), true);
      expect(
        scheduler.calls.first.operationId.value,
        isNot(scheduler.calls.last.operationId.value),
      );
    },
  );

  test('same operation replays; another file or arguments conflict', () async {
    final empty = await export();
    await populateSyntheticHistory();
    final file = await export();
    final revision = await liveSettingsRevision();
    final preview = await inspect(file);
    final operation = op();
    Future<RestoreReceipt> retry() async => f.success(
      await restorer.restoreBackup(
        operationId: operation,
        file: file,
        confirmation: RestoreConfirmation(
          preview: preview,
          expectedSettingsRevision: revision,
        ),
      ),
    );
    final first = await retry();
    final afterFirst = await dumpExcept(const {});
    final replayed = await retry();
    expect(replayed.sourceSha256, first.sourceSha256);
    expect(replayed.operationId, first.operationId);
    expect(replayed.schemaVersion.value, first.schemaVersion.value);
    expect(replayed.settings.revision, first.settings.revision);
    expect(await dumpExcept(const {}), afterFirst);
    expect(
      await restorer.restoreBackup(
        operationId: operation,
        file: empty,
        confirmation: RestoreConfirmation(
          preview: await inspect(empty),
          expectedSettingsRevision: revision,
        ),
      ),
      isA<Failure<RestoreReceipt>>().having(
        (result) => result.error,
        'error',
        isA<InvalidInput>(),
      ),
    );
    expect(await dumpExcept(const {}), afterFirst);
  });

  test(
    'confirmation binds digest, preview and live settings revision',
    () async {
      final other = await export();
      await populateSyntheticHistory();
      final file = await export();
      final revision = await liveSettingsRevision();
      final preview = await inspect(file);
      final before = await dumpExcept(const {});

      expect(
        await restorer.restoreBackup(
          operationId: op(),
          file: file,
          confirmation: RestoreConfirmation(
            preview: await inspect(other),
            expectedSettingsRevision: revision,
          ),
        ),
        isA<Failure<RestoreReceipt>>().having(
          (result) => result.error,
          'error',
          isA<InvalidInput>(),
        ),
      );
      expect(
        await restorer.restoreBackup(
          operationId: op(),
          file: file,
          confirmation: RestoreConfirmation(
            preview: preview,
            expectedSettingsRevision: revision.next(),
          ),
        ),
        isA<Failure<RestoreReceipt>>().having(
          (result) => result.error,
          'error',
          isA<StaleRevision>(),
        ),
      );
      expect(await dumpExcept(const {}), before);
      expect(sideFileNames(), {'data.sqlite'});
    },
  );

  test(
    'corrupt or truncated files fail closed and retain the original',
    () async {
      await populateSyntheticHistory();
      final file = await export();
      final before = await dumpExcept(const {});
      final flipped = BackupFile([
        ...file.bytes.take(file.bytes.length - 1),
        file.bytes.last ^ 1,
      ]);
      final truncated = BackupFile(file.bytes.sublist(0, 64));
      for (final broken in [flipped, truncated]) {
        final rejected = BackupPreview(
          version: BackupVersion(1),
          createdUtc: clock.utc,
          sha256: sha256.convert(broken.bytes).toString(),
          recordCounts: const {},
        );
        expect(
          await restorer.inspectBackup(broken),
          isA<Failure<BackupPreview>>().having(
            (result) => result.error,
            'error',
            isA<InvalidBackup>(),
          ),
        );
        expect(
          await restorer.restoreBackup(
            operationId: op(),
            file: broken,
            confirmation: RestoreConfirmation(
              preview: rejected,
              expectedSettingsRevision: await liveSettingsRevision(),
            ),
          ),
          isA<Failure<RestoreReceipt>>().having(
            (result) => result.error,
            'error',
            isA<InvalidBackup>(),
          ),
        );
      }
      expect(await dumpExcept(const {}), before);
      expect(
        f.success(await restorer.store.read((r) async => r.items())),
        isNotEmpty,
      );
    },
  );

  test(
    'newer versions are rejected; older sources convert explicitly',
    () async {
      await populateSyntheticHistory();
      final file = await export();
      final before = await dumpExcept(productTables);
      final snapshot = codec.decode(file).snapshot;
      final newerSchema = codec.encode(
        BackupSnapshot(
          createdUtc: snapshot.createdUtc,
          sourceSchemaVersion: SchemaVersion(currentBackupSchemaVersion + 1),
          currencyMetadataVersion: snapshot.currencyMetadataVersion,
          records: snapshot.records,
        ),
      );
      expect(
        await restorer.inspectBackup(newerSchema),
        isA<Failure<BackupPreview>>().having(
          (result) => result.error,
          'error',
          isA<UnsupportedBackupVersion>(),
        ),
      );

      // A version 2 envelope is rejected by the codec itself.
      final root = jsonDecode(utf8.decode(file.bytes)) as Map<String, dynamic>;
      root['version'] = 2;
      final newerEnvelope = BackupFile(utf8.encode(_canonicalJson(root)));
      expect(
        await restorer.inspectBackup(newerEnvelope),
        isA<Failure<BackupPreview>>().having(
          (result) => result.error,
          'error',
          isA<UnsupportedBackupVersion>(),
        ),
      );
      expect(await dumpExcept(productTables), before);

      // Older supported sources upgrade through the explicit converter chain.
      final older = codec.encode(
        BackupSnapshot(
          createdUtc: snapshot.createdUtc,
          sourceSchemaVersion: SchemaVersion(1),
          currencyMetadataVersion: snapshot.currencyMetadataVersion,
          records: snapshot.records,
        ),
      );
      final preview = await inspect(older);
      expect(preview.recordCounts, snapshot.recordCounts);
      await restore(older, preview: preview);
      rebuildRepositories();
      final converted = codec.decode(await export()).snapshot.records;
      for (final name in backupCollections.where((n) => n != 'operations')) {
        expect(converted[name], snapshot.records[name], reason: name);
      }
      expect(
        converted['operations']!.length,
        snapshot.records['operations']!.length + 1,
      );
    },
  );

  test('oversized files and foreign currency metadata are rejected', () async {
    await populateSyntheticHistory();
    final file = await export();
    final before = await dumpExcept(const {});

    final tight = await openRestorer(
      databaseFactoryFfi,
      codec: BackupCodec(
        limits: BackupLimits(maxRecords: 2, maxFileBytes: 1024),
      ),
    );
    expect(
      await tight.inspectBackup(file),
      isA<Failure<BackupPreview>>().having(
        (result) => result.error,
        'error',
        isA<InvalidBackup>(),
      ),
    );
    await tight.close();

    final snapshot = codec.decode(file).snapshot;
    final foreign = codec.encode(
      BackupSnapshot(
        createdUtc: snapshot.createdUtc,
        sourceSchemaVersion: snapshot.sourceSchemaVersion,
        currencyMetadataVersion: 'other-metadata-v9',
        records: snapshot.records,
      ),
    );
    expect(
      await restorer.inspectBackup(foreign),
      isA<Failure<BackupPreview>>().having(
        (result) => result.error,
        'error',
        isA<InvalidBackup>(),
      ),
    );
    expect(await dumpExcept(const {}), before);
  });

  test('duplicate records are rejected before any replacement', () async {
    await populateSyntheticHistory();
    final file = await export();
    final before = await dumpExcept(const {});
    final snapshot = codec.decode(file).snapshot;
    final mutated = {
      for (final entry in snapshot.records.entries)
        entry.key: [
          for (final record in entry.value) Map<String, Object?>.of(record),
        ],
    };
    for (final name in ['groups', 'operations', 'ledger', 'achievements']) {
      mutated[name]!.add(Map<String, Object?>.of(mutated[name]!.first));
    }
    final duplicated = codec.encode(
      BackupSnapshot(
        createdUtc: snapshot.createdUtc,
        sourceSchemaVersion: snapshot.sourceSchemaVersion,
        currencyMetadataVersion: snapshot.currencyMetadataVersion,
        records: mutated,
      ),
    );
    final preview = BackupPreview(
      version: BackupVersion(1),
      createdUtc: snapshot.createdUtc,
      sha256: sha256.convert(duplicated.bytes).toString(),
      recordCounts: {
        for (final entry in mutated.entries) entry.key: entry.value.length,
      },
    );
    expect(
      await restorer.inspectBackup(duplicated),
      isA<Failure<BackupPreview>>().having(
        (result) => result.error,
        'error',
        isA<InvalidBackup>().having(
          (error) => error.reason,
          'reason',
          'Duplicate record',
        ),
      ),
    );
    expect(
      await restorer.restoreBackup(
        operationId: op(),
        file: duplicated,
        confirmation: RestoreConfirmation(
          preview: preview,
          expectedSettingsRevision: await liveSettingsRevision(),
        ),
      ),
      isA<Failure<RestoreReceipt>>().having(
        (result) => result.error,
        'error',
        isA<InvalidBackup>(),
      ),
    );
    expect(await dumpExcept(const {}), before);
  });

  test('ledger and projection disagreement is rejected', () async {
    await populateSyntheticHistory();
    final file = await export();
    final before = await dumpExcept(const {});
    final snapshot = codec.decode(file).snapshot;
    final wallet = Map<String, Object?>.of(snapshot.records['wallet']!.single);
    final balances = Map<String, Object?>.from(wallet['balances'] as Map);
    balances['coins'] = '${int.parse(balances['coins'] as String) + 1}';
    wallet['balances'] = balances;
    final mutated = {
      for (final entry in snapshot.records.entries)
        entry.key: [
          for (final record in entry.value)
            identical(record, snapshot.records['wallet']!.single)
                ? wallet
                : record,
        ],
    };
    final inconsistent = codec.encode(
      BackupSnapshot(
        createdUtc: snapshot.createdUtc,
        sourceSchemaVersion: snapshot.sourceSchemaVersion,
        currencyMetadataVersion: snapshot.currencyMetadataVersion,
        records: mutated,
      ),
    );
    expect(
      await restorer.inspectBackup(inconsistent),
      isA<Failure<BackupPreview>>().having(
        (result) => result.error,
        'error',
        isA<InvalidBackup>().having(
          (error) => error.reason,
          'reason',
          'Ledger and projections disagree',
        ),
      ),
    );
    expect(await dumpExcept(const {}), before);
  });

  test('restores the checked-in portable v1 compatibility fixture', () async {
    final bytes = await File('test/data/fixtures/portable-v1.minutrove')
        .readAsBytes();
    final file = BackupFile(bytes);
    final preview = await inspect(file);
    expect(preview.recordCounts['ledger'], 7);
    expect(preview.createdUtc, DateTime.utc(2026, 1, 15, 12, 5));
    await restore(file, preview: preview);
    rebuildRepositories();
    final wallet = f.success(await restorer.store.read((r) => r.wallet()));
    expect(wallet.balances.coins.units, 9000000);
    expect(wallet.balances.gems.units, 200000);
    expect(f.success(await restorer.store.read((r) => r.items())).length, 2);
    final awards = f.success(await restorer.store.read((r) => r.awards()));
    expect(awards.single.time!.value, 60000);
    expect(awards.single.budget!.minorUnits, 2250);
    expect(
      f.success(await restorer.store.read((r) => r.achievements())).length,
      1,
    );
    // The restored history still replays its committed operation results.
    final replay = f.success(
      await restorer.store.read(
        (r) => r.operation<Object>(
          OperationId('00000000-0000-4000-8000-000000000006'),
        ),
      ),
    );
    expect(replay?.committedResult, isA<EconomicState>());
  });

  test('a running live session is replaced and its notification canceled', () async {
    final (q, _) = await populateSyntheticHistory();
    final file = await export();
    final running = await start(q);
    expect(
      f.success(await restorer.store.read((r) => r.activeSession()))!.id,
      running.session.id,
    );

    await restore(file);
    rebuildRepositories();
    expect(
      f.success(await restorer.store.read((r) => r.activeSession())),
      isNull,
    );
    expect(
      f.success(await restorer.store.read((r) => r.notificationIntents())),
      isEmpty,
    );
    expect(scheduler.calls.single.intents, isEmpty);
    // The replaced running session left no economic trace beyond the snapshot.
    final ledger = f.success(await restorer.store.read((r) => r.ledger()));
    expect(
      ledger.every((entry) => entry.sessionId != running.session.id),
      true,
    );
  });

  test('write failures during validation retain the usable original', () async {
    await restorer.close();
    final faults = FaultFactory();
    restorer = await openRestorer(faults);
    rebuildRepositories();
    await populateSyntheticHistory();
    final file = await export();
    final before = await dumpExcept(const {});
    final preview = await inspect(file);

    faults.arm(failure: 3);
    expect(
      await restorer.restoreBackup(
        operationId: op(),
        file: file,
        confirmation: RestoreConfirmation(
          preview: preview,
          expectedSettingsRevision: await liveSettingsRevision(),
        ),
      ),
      isA<Failure<RestoreReceipt>>().having(
        (result) => result.error,
        'error',
        isA<StorageUnavailable>().having(
          (error) => error.retryable,
          'retryable',
          true,
        ),
      ),
    );
    faults.disarm();
    expect(await dumpExcept(const {}), before);
    expect(
      f.success(await restorer.store.read((r) async => r.items())),
      isNotEmpty,
    );
    expect(sideFileNames(), contains('data.sqlite'));
  });

  for (final (name, interruptedOpen) in [
    ('safety verification', 2),
    ('live reopen after rename', 3),
  ]) {
    test(
      'interrupted replacement at $name retains a usable original',
      () async {
        await restorer.close();
        final faults = FaultFactory();
        restorer = await openRestorer(faults);
        rebuildRepositories();
        await populateSyntheticHistory();
        final file = await export();
        final before = await dumpExcept(const {});
        final preview = await inspect(file);

        faults.arm(openFailure: interruptedOpen);
        expect(
          await restorer.restoreBackup(
            operationId: op(),
            file: file,
            confirmation: RestoreConfirmation(
              preview: preview,
              expectedSettingsRevision: await liveSettingsRevision(),
            ),
          ),
          isA<Failure<RestoreReceipt>>().having(
            (result) => result.error,
            'error',
            isA<StorageUnavailable>(),
          ),
        );
        faults.disarm();
        expect(await dumpExcept(const {}), before);
        expect(
          f.success(await restorer.store.read((r) async => r.items())),
          isNotEmpty,
        );
        expect(scheduler.calls, isEmpty);
      },
    );
  }
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

final class RecordingScheduler implements NotificationScheduler {
  final calls =
      <({OperationId operationId, List<NotificationIntent> intents})>[];

  @override
  Future<NotificationPermission> permission() async =>
      NotificationPermission.granted;

  @override
  Future<NotificationPermission> requestPermission({
    required OperationId operationId,
  }) async => NotificationPermission.granted;

  @override
  Future<Result<NotificationPermission>> reconcile({
    required OperationId operationId,
    required List<NotificationIntent> intents,
  }) async {
    calls.add((operationId: operationId, intents: List.of(intents)));
    return const Success(NotificationPermission.granted);
  }

  @override
  Future<Result<bool>> openSystemSettings({
    required OperationId operationId,
  }) async => const Success(true);
}
