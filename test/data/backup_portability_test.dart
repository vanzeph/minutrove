import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/backup_portability.dart' as p;
import 'fault_database.dart';

void main() {
  sqfliteFfiInit();
  late Directory directory;
  var serial = 9000;
  OperationId op() => OperationId(
    '00000000-0000-4000-8000-${(serial++).toString().padLeft(12, '0')}',
  );
  String path(String name) => '${directory.path}/$name.sqlite';

  Future<SqliteBackupRestorer> openRestorer(
    String name, {
    DatabaseFactory? factory,
  }) async => p.success(
    await SqliteBackupRestorer.open(
      path: path(name),
      factory: factory ?? databaseFactoryFfi,
      currencies: p.portabilityCurrencies,
      initialSettings: p.portabilitySettings,
      clock: p.PortabilityClock(),
      calendar: p.portabilityCalendar,
    ),
  );

  setUp(() async {
    serial = 9000;
    directory = await Directory.systemTemp.createTemp('minutrove-portability-');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<Map<String, dynamic>> dump(String name) async {
    final db = await databaseFactoryFfi.openDatabase(
      path(name),
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
      );
      return {
        for (final table in tables)
          table['name'] as String: await db.query(
            table['name'] as String,
            orderBy: 'rowid',
          ),
      };
    } finally {
      await db.close();
    }
  }

  test(
    'the deterministic history regenerates the committed reference bytes',
    () async {
      final world = await p.buildPortabilityHistory(
        path: path('source'),
        factory: databaseFactoryFfi,
      );
      try {
        final file = await world.export();
        final reference = await File(p.portabilityReferencePath).readAsBytes();
        // Same data and date produce identical bytes; the committed artifact
        // pins what every platform must reproduce for a transferable backup.
        expect(file.bytes, reference);
        expect(
          sha256.convert(file.bytes).toString(),
          p.portabilityReferenceSha256,
        );

        final coverage = await p.portabilityCoverage(file);
        expect(coverage['years'], [2023, 2024, 2025, 2026]);
        expect(coverage['budgetPrecisions'], [0, 2, 3]);
        // Every minor-unit precision class the pinned table defines.
        final digits = <int>{
          for (final code in [
            'USD',
            'JPY',
            'BHD',
            'KWD',
            'KRW',
            'VND',
            'EUR',
            'TND',
          ])
            p.portabilityCurrencies.minorDigitsFor(code)!,
        };
        expect(digits, {0, 2, 3});
        expect(coverage['archived'], [p.questWork.value, p.awardCharm.value]);
        expect(coverage['achievements'], 5);
        expect(
          (coverage['remaindersNonZero'] as List).length,
          greaterThanOrEqualTo(3),
          reason: 'Quest/currency remainder carry must survive the transfer',
        );
        expect(coverage['createdUtc'], p.portabilityCreatedUtc);
        expect(
          (coverage['recordCounts'] as Map)['sessions'],
          13,
          reason: 'Multi-year ended/completed history exports completely',
        );
        final state = await p.portabilityDomainState(world.store);
        expect(state['wallet'], '16:43925000344/68850009');
      } finally {
        await world.close();
      }
    },
  );

  test('restoring the reference into a fresh store preserves exact state and Stats', () async {
    final source = await p.buildPortabilityHistory(
      path: path('source'),
      factory: databaseFactoryFfi,
    );
    final target = await openRestorer('target');
    try {
      final reference = await File(p.portabilityReferencePath).readAsBytes();
      final file = BackupFile(reference);
      final beforeStats = await p.portabilityStatsBattery(source.store);
      final beforeState = await p.portabilityDomainState(source.store);

      final preview = p.success(await target.inspectBackup(file));
      expect(preview.sha256, p.portabilityReferenceSha256);
      expect(preview.createdUtc, p.portabilityCreatedUtc);
      expect(preview.version.value, 1);
      final liveSettings = p.success(
        await target.store.read((r) => r.settings()),
      );
      final receipt = p.success(
        await target.restoreBackup(
          operationId: op(),
          file: file,
          confirmation: RestoreConfirmation(
            preview: preview,
            expectedSettingsRevision: liveSettings.revision,
          ),
        ),
      );
      expect(receipt.sourceSha256, p.portabilityReferenceSha256);
      expect(receipt.settings.reportingZone.ianaName, 'Europe/Berlin');

      // Exact domain state and the full Stats battery agree with source.
      expect(await p.portabilityDomainState(target.store), beforeState);
      expect(await p.portabilityStatsBattery(target.store), beforeStats);
      expect(
        p.success(await target.store.read((r) => r.activeSession())),
        isNull,
        reason: 'An imported snapshot contains no active session',
      );
      expect(
        p.success(await target.store.read((r) => r.projectionMismatches())),
        isEmpty,
      );

      // Re-exporting the restored store reproduces the reference records;
      // only the durable restore operation joins the history.
      final reexported = p.success(
        await SqliteBackupRepository(
          restorer: target,
          clock: _exportClock(),
        ).exportBackup(operationId: op()),
      );
      final referenceRecords = const BackupCodec()
          .decode(file)
          .snapshot
          .records;
      final restoredRecords = const BackupCodec()
          .decode(reexported)
          .snapshot
          .records;
      for (final name in backupCollections.where((n) => n != 'operations')) {
        expect(restoredRecords[name], referenceRecords[name], reason: name);
      }
      expect(
        restoredRecords['operations']!.length,
        referenceRecords['operations']!.length + 1,
      );

      // The restored store keeps serving ordinary commands.
      final items = SqliteItemRepository(
        store: target.store,
        clock: p.PortabilityClock(),
        calendar: p.portabilityCalendar,
      );
      p.success(
        await items.saveGroup(
          operationId: op(),
          group: Group(
            id: GroupId(
              '00000000-0000-4000-8000-${(901).toString().padLeft(12, '0')}',
            ),
            revision: Revision(1),
            name: 'After restore',
            order: 9,
          ),
          expectedRevision: null,
        ),
      );
    } finally {
      await source.close();
      await target.close();
    }
  });

  test(
    'an export from one store restores into another with identical results',
    () async {
      final source = await p.buildPortabilityHistory(
        path: path('source'),
        factory: databaseFactoryFfi,
      );
      final target = await openRestorer('target');
      try {
        final transferred = await source.export();
        final preview = p.success(await target.inspectBackup(transferred));
        final liveSettings = p.success(
          await target.store.read((r) => r.settings()),
        );
        p.success(
          await target.restoreBackup(
            operationId: op(),
            file: transferred,
            confirmation: RestoreConfirmation(
              preview: preview,
              expectedSettingsRevision: liveSettings.revision,
            ),
          ),
        );
        expect(
          await p.portabilityDomainState(target.store),
          await p.portabilityDomainState(source.store),
        );
        expect(
          await p.portabilityStatsBattery(target.store),
          await p.portabilityStatsBattery(source.store),
        );
      } finally {
        await source.close();
        await target.close();
      }
    },
  );

  test('a stale confirmation against moved live settings is rejected before any file is touched', () async {
    final source = await p.buildPortabilityHistory(
      path: path('source'),
      factory: databaseFactoryFfi,
    );
    final target = await openRestorer('target');
    try {
      final file = BackupFile(
        await File(p.portabilityReferencePath).readAsBytes(),
      );
      final preview = p.success(await target.inspectBackup(file));
      final settings = SqliteSettingsRepository(
        store: target.store,
        clock: p.PortabilityClock(),
        calendar: p.portabilityCalendar,
      );
      p.success(
        await settings.saveSettings(
          operationId: op(),
          expectedRevision: Revision(1),
          reportingZone: ReportingZone('Etc/UTC'),
        ),
      );
      final before = await dump('target');
      final result = await target.restoreBackup(
        operationId: op(),
        file: file,
        confirmation: RestoreConfirmation(
          preview: preview,
          expectedSettingsRevision: Revision(1),
        ),
      );
      expect(
        result,
        isA<Failure<RestoreReceipt>>().having(
          (result) => result.error,
          'error',
          isA<StaleRevision>(),
        ),
      );
      expect(await dump('target'), before);
    } finally {
      await source.close();
      await target.close();
    }
  });

  for (final (name, mutation) in [
    ('a flipped payload byte', 'corrupt'),
    ('a truncated tail', 'truncate'),
    ('a version from the future', 'future-version'),
    ('foreign pinned currency metadata', 'foreign-currencies'),
  ]) {
    test('$name fails typed and leaves the live original usable', () async {
      final live = await openRestorer('live');
      try {
        final items = SqliteItemRepository(
          store: live.store,
          clock: p.PortabilityClock(),
          calendar: p.portabilityCalendar,
        );
        final quest = Item(
          id: p.questStudy,
          revision: Revision(1),
          name: 'Live-only quest',
          iconKey: 'gamepad',
          colorArgb: 0xff883366,
          groupId: null,
          order: 0,
          archived: false,
          configuration: QuestConfiguration(
            duration: Milliseconds.seconds(60),
            ratesPerHour: CurrencyAmounts(
              coins: MicroAmount(1000000),
              gems: MicroAmount(0),
            ),
          ),
        );
        p.success(
          await items.saveItem(
            operationId: op(),
            item: quest,
            expectedRevision: null,
          ),
        );
        final file = p.mutatedBackup(
          await File(p.portabilityReferencePath).readAsBytes(),
          mutation,
        );
        final before = await dump('live');

        final inspected = await live.inspectBackup(file);
        expect(inspected, isA<Failure<BackupPreview>>());
        final restored = await live.restoreBackup(
          operationId: op(),
          file: file,
          confirmation: RestoreConfirmation(
            preview: BackupPreview(
              version: BackupVersion(1),
              createdUtc: p.portabilityCreatedUtc,
              sha256: sha256.convert(file.bytes).toString(),
              recordCounts: const {},
            ),
            expectedSettingsRevision: Revision(1),
          ),
        );
        expect(restored, isA<Failure<RestoreReceipt>>());

        expect(await dump('live'), before);
        expect(
          p.success(await live.store.read((r) => r.items())).single.name,
          'Live-only quest',
          reason: 'The original stays readable after a failed restore',
        );
        p.success(
          await items.saveGroup(
            operationId: op(),
            group: Group(
              id: GroupId(
                '00000000-0000-4000-8000-${(902).toString().padLeft(12, '0')}',
              ),
              revision: Revision(1),
              name: 'Still writable',
              order: 0,
            ),
            expectedRevision: null,
          ),
        );
      } finally {
        await live.close();
      }
    });
  }

  for (final (name, openFailure) in [
    ('safety verification', 2),
    ('live reopen after rename', 3),
  ]) {
    test(
      'interrupted replacement at $name retains a usable original',
      () async {
        final faults = FaultFactory();
        final live = await openRestorer('live', factory: faults);
        try {
          final file = BackupFile(
            await File(p.portabilityReferencePath).readAsBytes(),
          );
          final preview = p.success(await live.inspectBackup(file));
          final before = await dump('live');

          faults.arm(openFailure: openFailure);
          final restored = await live.restoreBackup(
            operationId: op(),
            file: file,
            confirmation: RestoreConfirmation(
              preview: preview,
              expectedSettingsRevision: Revision(1),
            ),
          );
          faults.disarm();
          expect(
            restored,
            isA<Failure<RestoreReceipt>>().having(
              (result) => result.error,
              'error',
              isA<StorageUnavailable>(),
            ),
          );
          expect(await dump('live'), before);
          expect(
            p.success(await live.store.read((r) => r.items())),
            isEmpty,
            reason: 'Nothing from the failed restore leaked into the original',
          );
        } finally {
          await live.close();
        }
      },
    );
  }
}

Clock _exportClock() {
  final clock = p.PortabilityClock();
  clock.at(2026, 3, 15, 8, 30);
  return clock;
}
