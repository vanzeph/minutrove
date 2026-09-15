import '../domain/domain.dart';
import 'schema.dart';

/// Logical backup schema version restore currently materializes into. It
/// follows the newest database migration; a future migration that changes the
/// portable contract must add a converter here and keep older fixtures valid.
final int currentBackupSchemaVersion = schemaMigrations.last.version;

/// One explicit upgrade step between adjacent logical backup schema versions.
/// Converters see only validated, codec-shaped records; they never touch live
/// data and must stay total (no user interaction, no storage access).
final class BackupConverter {
  const BackupConverter({
    required this.from,
    required this.to,
    required this.apply,
  });

  /// Source [BackupSnapshot.sourceSchemaVersion] this step accepts.
  final int from;

  /// Version the returned snapshot must declare.
  final int to;

  /// Pure record transformation; returns a snapshot already declaring [to].
  final BackupSnapshot Function(BackupSnapshot snapshot) apply;
}

BackupSnapshot _schema1To2(BackupSnapshot snapshot) => BackupSnapshot(
  createdUtc: snapshot.createdUtc,
  sourceSchemaVersion: SchemaVersion(2),
  currencyMetadataVersion: snapshot.currencyMetadataVersion,
  records: snapshot.records,
);

/// Explicit converter chain from the oldest supported backup source schema to
/// [currentBackupSchemaVersion]. Database schema 2 added a statistics index
/// only, so the version 1 logical collections and record shapes are identical.
final List<BackupConverter> backupConverters = List.unmodifiable([
  BackupConverter(from: 1, to: 2, apply: _schema1To2),
]);

/// Upgrades a decoded snapshot to [target] through the converter chain.
/// Snapshots newer than the target are rejected as
/// [UnsupportedBackupVersion] without any mutation; a malformed chain is a
/// programming error surfaced as [InvalidInput].
BackupSnapshot upgradeBackupSnapshot(
  BackupSnapshot snapshot, {
  List<BackupConverter>? chain,
  int? target,
}) {
  final converters = chain ?? backupConverters;
  final goal = target ?? currentBackupSchemaVersion;
  for (var i = 0; i < converters.length; i++) {
    final converter = converters[i];
    if (converter.from < 1 ||
        converter.to != converter.from + 1 ||
        (i > 0 && converters[i - 1].to != converter.from) ||
        (i == 0 && converter.from != 1) ||
        (i == converters.length - 1 && converter.to != goal)) {
      throw const InvalidInput(
        'converters',
        'Expected one contiguous chain ending at the target',
      );
    }
  }
  if (converters.isEmpty && goal != 1) {
    throw const InvalidInput(
      'converters',
      'Expected one contiguous chain ending at the target',
    );
  }
  final source = snapshot.sourceSchemaVersion.value;
  if (source > goal) {
    throw UnsupportedBackupVersion(source);
  }
  var current = snapshot;
  var version = source;
  while (version < goal) {
    BackupConverter? step;
    for (final converter in converters) {
      if (converter.from == version) step = converter;
    }
    if (step == null) {
      throw const InvalidInput(
        'converters',
        'Expected one contiguous chain ending at the target',
      );
    }
    current = step.apply(current);
    if (current.sourceSchemaVersion.value != step.to) {
      throw const InvalidBackup('Converter produced an unexpected version');
    }
    version = step.to;
  }
  return current;
}
