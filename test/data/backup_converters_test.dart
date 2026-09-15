import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';

import 'support.dart' as f;

BackupSnapshot snapshotOf(int version) => BackupSnapshot(
  createdUtc: f.now,
  sourceSchemaVersion: SchemaVersion(version),
  currencyMetadataVersion: f.metadata.version,
  records: {
    for (final name in backupCollections) name: <Map<String, Object?>>[],
  },
);

/// Correct chain step: bumps the declared version and preserves the records.
BackupSnapshot bump(BackupSnapshot snapshot) => BackupSnapshot(
  createdUtc: snapshot.createdUtc,
  sourceSchemaVersion: SchemaVersion(snapshot.sourceSchemaVersion.value + 1),
  currencyMetadataVersion: snapshot.currencyMetadataVersion,
  records: snapshot.records,
);

void main() {
  test('upgrade applies the explicit chain and preserves records', () {
    final upgraded = upgradeBackupSnapshot(snapshotOf(1));
    expect(upgraded.sourceSchemaVersion.value, currentBackupSchemaVersion);
    expect(upgraded.createdUtc, f.now);
    expect(upgraded.currencyMetadataVersion, f.metadata.version);
    expect(upgraded.recordCounts.values.every((count) => count == 0), true);
    expect(upgradeBackupSnapshot(snapshotOf(2)).records, upgraded.records);
  });

  test('newer snapshots are rejected without mutation', () {
    expect(
      () => upgradeBackupSnapshot(snapshotOf(currentBackupSchemaVersion + 1)),
      throwsA(
        isA<UnsupportedBackupVersion>().having(
          (error) => error.version,
          'version',
          currentBackupSchemaVersion + 1,
        ),
      ),
    );
  });

  test('malformed chains are programming errors', () {
    for (final chain in [
      [BackupConverter(from: 2, to: 3, apply: bump)],
      [BackupConverter(from: 1, to: 3, apply: bump)],
      [
        BackupConverter(from: 1, to: 2, apply: bump),
        BackupConverter(from: 1, to: 2, apply: bump),
      ],
    ]) {
      expect(
        () => upgradeBackupSnapshot(snapshotOf(1), chain: chain),
        throwsA(
          isA<InvalidInput>().having(
            (error) => error.field,
            'field',
            'converters',
          ),
        ),
      );
    }
  });

  test('a converter must declare its target version', () {
    expect(
      () => upgradeBackupSnapshot(
        snapshotOf(1),
        chain: [BackupConverter(from: 1, to: 2, apply: (s) => s)],
      ),
      throwsA(isA<InvalidBackup>()),
    );
  });
}
