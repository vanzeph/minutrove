import 'ports.dart';
import 'records.dart';
import 'result.dart';

/// Resource bounds are enforced before database materialization and while
/// encoding/decoding. Lower limits can be injected by tests or constrained hosts.
final class BackupLimits {
  const BackupLimits({
    this.maxFileBytes = 64 * 1024 * 1024,
    this.maxRecordBytes = 1024 * 1024,
    this.maxRecords = 250000,
    this.maxDepth = 32,
  });
  final int maxFileBytes;
  final int maxRecordBytes;
  final int maxRecords;
  final int maxDepth;

  void validate() {
    if (maxFileBytes <= 0 ||
        maxRecordBytes <= 0 ||
        maxRecords <= 0 ||
        maxDepth < 1 ||
        maxDepth > 64) {
      throw const InvalidBackup('Invalid resource limits');
    }
  }
}

/// V1 logical collections, independent of SQL tables and internal result JSON.
/// Intervals belong to their session; notification/OS state has no collection.
const backupCollections = <String>[
  'groups',
  'items',
  'itemRevisions',
  'sessions',
  'operations',
  'ledger',
  'wallet',
  'awardBalances',
  'accrualRemainders',
  'goalRevisions',
  'achievements',
  'settings',
];

/// An immutable logical snapshot. Record fields follow the public v1 format;
/// exact integers are decimal strings, so a JSON double cannot round balances.
/// This is data only: neither construction nor decoding authorizes restoration.
final class BackupSnapshot {
  BackupSnapshot({
    required this.createdUtc,
    required this.sourceSchemaVersion,
    required this.currencyMetadataVersion,
    required Map<String, List<Map<String, Object?>>> records,
  }) : records = Map.unmodifiable({
         for (final entry in records.entries)
           entry.key: List<Map<String, Object?>>.unmodifiable(
             entry.value.map(
               (record) => _freeze(record) as Map<String, Object?>,
             ),
           ),
       }) {
    if (!createdUtc.isUtc || currencyMetadataVersion.trim().isEmpty) {
      throw const InvalidBackup('Invalid snapshot metadata');
    }
    if (records.length != backupCollections.length ||
        !backupCollections.every(records.containsKey)) {
      throw const InvalidBackup('Invalid snapshot collections');
    }
  }

  final DateTime createdUtc;
  final SchemaVersion sourceSchemaVersion;
  final String currencyMetadataVersion;
  final Map<String, List<Map<String, Object?>>> records;
  Map<String, int> get recordCounts => Map.unmodifiable({
    for (final entry in records.entries) entry.key: entry.value.length,
  });
}

Object? _freeze(Object? value, [int depth = 0]) {
  if (depth > 64) throw const InvalidBackup('Record nesting limit exceeded');
  if (value == null || value is String || value is bool) return value;
  if (value is List) {
    return List<Object?>.unmodifiable(value.map((v) => _freeze(v, depth + 1)));
  }
  if (value is Map<String, Object?>) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key: _freeze(entry.value, depth + 1),
    });
  }
  throw const InvalidBackup('Expected exact portable record values');
}

/// Envelope integrity and record syntax only. A restore adapter must still
/// validate relationships, economic invariants and compatibility in a temporary
/// store, then obtain replacement confirmation before touching live data.
final class DecodedBackup {
  const DecodedBackup({required this.snapshot, required this.preview});
  final BackupSnapshot snapshot;
  final BackupPreview preview;
}
