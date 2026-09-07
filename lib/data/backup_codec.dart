import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/domain.dart';

/// Canonical, unencrypted UTF-8 JSON. Digest covers the entire payload, including
/// source date, schema, currency metadata and counts. It detects corruption, not
/// a malicious author who can recompute an unsigned digest.
final class BackupCodec {
  const BackupCodec({this.limits = const BackupLimits()});
  static const format = 'minutrove';
  static const version = 1;
  static const extension = '.minutrove';
  final BackupLimits limits;

  /// Incremental snapshot readers use the same bounded encoder before retaining
  /// each record. No full unbounded JSON string is created to measure its size.
  int recordByteLength(Map<String, Object?> record) {
    limits.validate();
    _record(record, 0);
    return _encode(record, limits.maxRecordBytes).length;
  }

  BackupFile encode(BackupSnapshot snapshot) {
    limits.validate();
    _validateRecords(snapshot.records);
    final payload = {
      'createdUtc': snapshot.createdUtc.toIso8601String(),
      'sourceSchemaVersion': snapshot.sourceSchemaVersion.value,
      'currencyMetadataVersion': snapshot.currencyMetadataVersion,
      'recordCounts': snapshot.recordCounts,
      'records': snapshot.records,
    };
    final payloadBytes = _encode(payload, limits.maxFileBytes);
    return BackupFile(
      _encode({
        'format': format,
        'version': version,
        'payload': payload,
        'integrity': {
          'algorithm': 'sha256',
          'payloadBytes': payloadBytes.length,
          'sha256': sha256.convert(payloadBytes).toString(),
        },
      }, limits.maxFileBytes),
    );
  }

  /// Syntax/integrity inspection is read-only and never sufficient to restore.
  /// Canonical bytes are required, rejecting duplicate JSON keys, ambiguous
  /// numeric spellings, alternate escapes and unauthenticated trailing data.
  DecodedBackup decode(BackupFile file) {
    limits.validate();
    try {
      final bytes = file.bytes;
      if (bytes.length > limits.maxFileBytes) {
        throw const InvalidBackup('File size limit exceeded');
      }
      _checkNesting(bytes);
      final root = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      _keys(root, ['format', 'version', 'payload', 'integrity']);
      if (root['format'] != format || root['version'] is! int) {
        throw const InvalidBackup('Unrecognized format');
      }
      if (root['version'] != version) {
        throw UnsupportedBackupVersion(root['version'] as int);
      }
      final canonical = _encode(root, limits.maxFileBytes);
      if (!_equal(bytes, canonical)) {
        throw const InvalidBackup('Noncanonical file');
      }
      final payload = root['payload'] as Map<String, dynamic>;
      _keys(payload, [
        'createdUtc',
        'sourceSchemaVersion',
        'currencyMetadataVersion',
        'recordCounts',
        'records',
      ]);
      final integrity = root['integrity'] as Map<String, dynamic>;
      _keys(integrity, ['algorithm', 'payloadBytes', 'sha256']);
      final payloadBytes = _encode(payload, limits.maxFileBytes);
      if (integrity['algorithm'] != 'sha256' ||
          integrity['payloadBytes'] is! int ||
          integrity['payloadBytes'] != payloadBytes.length ||
          integrity['sha256'] != sha256.convert(payloadBytes).toString()) {
        throw const InvalidBackup('Integrity check failed');
      }
      final raw = payload['records'] as Map<String, dynamic>;
      final records = <String, List<Map<String, Object?>>>{
        for (final entry in raw.entries)
          entry.key: (entry.value as List)
              .map((v) => Map<String, Object?>.from(v as Map))
              .toList(),
      };
      _validateRecords(records);
      final snapshot = BackupSnapshot(
        createdUtc: DateTime.parse(payload['createdUtc'] as String),
        sourceSchemaVersion: SchemaVersion(
          payload['sourceSchemaVersion'] as int,
        ),
        currencyMetadataVersion: payload['currencyMetadataVersion'] as String,
        records: records,
      );
      if (jsonEncode(_canonical(payload['recordCounts'])) !=
          jsonEncode(_canonical(snapshot.recordCounts))) {
        throw const InvalidBackup('Record counts disagree');
      }
      return DecodedBackup(
        snapshot: snapshot,
        preview: BackupPreview(
          version: BackupVersion(version),
          createdUtc: snapshot.createdUtc,
          sha256: sha256.convert(bytes).toString(),
          recordCounts: snapshot.recordCounts,
        ),
      );
    } on UnsupportedBackupVersion {
      rethrow;
    } on InvalidBackup {
      rethrow;
    } catch (_) {
      // Never include imported file contents in errors or diagnostics.
      throw const InvalidBackup('Malformed backup');
    }
  }

  void _validateRecords(Map<String, List<Map<String, Object?>>> records) {
    _keys(records, backupCollections);
    var count = 0;
    for (final entry in records.entries) {
      count += entry.value.length;
      if (count > limits.maxRecords) {
        throw const InvalidBackup('Record count limit exceeded');
      }
      for (final record in entry.value) {
        if (record['type'] != _collectionTypes[entry.key]) {
          throw const InvalidBackup('Wrong collection record type');
        }
        recordByteLength(record);
        if (entry.key == 'sessions' &&
            record['status'] != 'ended' &&
            record['status'] != 'completed') {
          throw const InvalidBackup('Snapshot contains an active session');
        }
      }
    }
    if (records['wallet']!.length != 1 || records['settings']!.length != 1) {
      throw const InvalidBackup('Missing singleton');
    }
  }

  void _record(Map<Object?, Object?> record, int depth) {
    if (depth > limits.maxDepth) {
      throw const InvalidBackup('Record nesting limit exceeded');
    }
    final fields = _recordFields[record['type']];
    if (fields == null) throw const InvalidBackup('Unknown record type');
    _keys(record, ['type', ...fields.keys]);
    for (final field in fields.entries) {
      final value = record[field.key];
      var shape = field.value;
      if (shape.startsWith('?')) {
        if (value == null) continue;
        shape = shape.substring(1);
      }
      switch (shape) {
        case 's':
          if (value is! String) throw const InvalidBackup('Expected text');
        case 'b':
          if (value is! bool) throw const InvalidBackup('Expected boolean');
        case 'i':
          if (value is! String ||
              !RegExp(r'^(0|-?[1-9][0-9]*)$').hasMatch(value) ||
              int.tryParse(value) == null) {
            throw const InvalidBackup('Expected signed 64-bit decimal integer');
          }
        case 'r':
          if (value is! Map) throw const InvalidBackup('Expected record');
          _record(value, depth + 1);
        case 'l':
          if (value is! List || value.length > limits.maxRecords) {
            throw const InvalidBackup('Record list limit exceeded');
          }
          for (final child in value) {
            if (child is! Map) throw const InvalidBackup('Expected record');
            _record(child, depth + 1);
          }
      }
    }
  }

  void _checkNesting(List<int> bytes) {
    var depth = 0;
    var quoted = false;
    var escaped = false;
    for (final byte in bytes) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (byte == 92) {
          escaped = true;
        } else if (byte == 34) {
          quoted = false;
        }
      } else if (byte == 34) {
        quoted = true;
      } else if (byte == 123 || byte == 91) {
        // Envelope/collections add a bounded amount beyond record depth.
        if (++depth > limits.maxDepth + 6) {
          throw const InvalidBackup('File nesting limit exceeded');
        }
      } else if (byte == 125 || byte == 93) {
        depth--;
      }
    }
  }
}

const _collectionTypes = {
  'groups': 'group',
  'items': 'item',
  'itemRevisions': 'itemRevision',
  'sessions': 'session',
  'operations': 'operation',
  'ledger': 'ledger',
  'wallet': 'wallet',
  'awardBalances': 'balance',
  'accrualRemainders': 'remainder',
  'goalRevisions': 'goalRevision',
  'achievements': 'achievement',
  'settings': 'settings',
};

// s=text, i=exact integer string, b=boolean, r=record, l=record list; ?=nullable.
// Relationship and semantic validation belong to the temporary restore store.
const _recordFields = <String, Map<String, String>>{
  'operation': {
    'id': 's',
    'kind': 's',
    'fingerprint': 's',
    'at': 'r',
    'result': 'r',
  },
  'item': {
    'id': 's',
    'revision': 'i',
    'name': 's',
    'icon': 's',
    'color': 'i',
    'group': '?s',
    'order': 'i',
    'archived': 'b',
    'config': 'r',
  },
  'quest': {'duration': 'i', 'rates': 'r', 'goal': '?r'},
  'award': {
    'pack': 's',
    'step': 'i',
    'price': 'r',
    'time': '?i',
    'budget': '?r',
  },
  'amounts': {'coins': 'i', 'gems': 'i'},
  'budget': {'currency': 's', 'digits': 'i', 'minor': 'i'},
  'goal': {'target': 'i', 'bonus': 'r'},
  'group': {'id': 's', 'revision': 'i', 'name': 's', 'order': 'i'},
  'event': {'utc': 'i', 'day': 's', 'zone': 's', 'offset': 'i'},
  'instant': {'utc': 'i'},
  'itemRevision': {'item': 'r', 'at': 'r'},
  'interval': {'start': 'r', 'end': 'r', 'active': 'i', 'at': 'r'},
  'session': {
    'id': 's',
    'revision': 'i',
    'item': 'r',
    'status': 's',
    'zone': 's',
    'start': 'r',
    'checkpoint': 'r',
    'duration': 'i',
    'settled': 'i',
    'completion': 's',
    'intervals': 'l',
  },
  'ledger': {
    'id': 's',
    'operation': 's',
    'item': 's',
    'revision': 'i',
    'session': '?s',
    'at': 'r',
    'dimension': 'r',
    'delta': 'i',
  },
  'virtualDimension': {'currency': 's'},
  'timeDimension': {},
  'budgetDimension': {'currency': 's', 'digits': 'i'},
  'wallet': {'revision': 'i', 'balances': 'r'},
  'balance': {'id': 's', 'revision': 'i', 'time': '?i', 'budget': '?r'},
  'remainder': {'id': 's', 'currency': 's', 'value': 'i'},
  'goalRevision': {
    'id': 's',
    'revision': 'i',
    'day': 's',
    'zone': 's',
    'goal': '?r',
  },
  'achievement': {
    'id': 's',
    'day': 's',
    'revision': 'i',
    'operation': 's',
    'at': 'r',
    'bonus': 'r',
  },
  'settings': {'revision': 'i', 'zone': 's'},
  'schema': {'value': 'i'},
  'economy': {
    'operation': 's',
    'wallet': 'r',
    'awards': 'l',
    'session': '?r',
    'entries': 'l',
    'achievements': 'l',
  },
  'sessionMutation': {'session': 'r', 'economy': 'r'},
  'restoreReceipt': {
    'operation': 's',
    'sha256': 's',
    'schema': 'r',
    'settings': 'r',
  },
  'items': {'items': 'l'},
  'bool': {'value': 'b'},
};

void _keys(Map<Object?, Object?> value, List<String> keys) {
  if (value.length != keys.length || !keys.every(value.containsKey)) {
    throw const InvalidBackup('Unexpected or missing fields');
  }
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

Uint8List _encode(Object value, int limit) {
  final sink = _BoundedBytes(limit);
  final encoder = JsonUtf8Encoder().startChunkedConversion(sink);
  encoder.add(_canonical(value));
  encoder.close();
  return sink.builder.takeBytes();
}

final class _BoundedBytes implements Sink<List<int>> {
  _BoundedBytes(this.limit);
  final int limit;
  final builder = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (data.length > limit - builder.length) {
      throw const InvalidBackup('Encoded size limit exceeded');
    }
    builder.add(data);
  }

  @override
  void close() {}
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
