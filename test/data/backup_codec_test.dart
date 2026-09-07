import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';

import 'support.dart' as f;

void main() {
  const codec = BackupCodec();
  const records = BackupRecordCodec();
  BackupSnapshot snapshot() => BackupSnapshot(
    createdUtc: f.now,
    sourceSchemaVersion: SchemaVersion(2),
    currencyMetadataVersion: f.metadata.version,
    records: {
      for (final name in backupCollections) name: <Map<String, Object?>>[],
      'wallet': [
        records.toJson(
          WalletProjection(
            revision: Revision(1),
            balances: f.amounts(maxStoredInteger),
          ),
        ),
      ],
      'settings': [records.toJson(f.settings)],
      'items': [records.toJson(f.quest(name: 'Synthetic 学习 🎮'))],
      'ledger': [
        records.toJson(
          f.entry(
            f.quest(),
            const VirtualCurrencyDimension(VirtualCurrency.coins),
            -maxStoredInteger - 1,
          ),
        ),
      ],
    },
  );

  test(
    'signed 64-bit extremes, Unicode and metadata round trip without doubles',
    () {
      final original = snapshot();
      final decoded = codec.decode(codec.encode(original));
      expect(decoded.snapshot.records, original.records);
      expect(
        (decoded.snapshot.records['wallet']!.single['balances']
            as Map)['coins'],
        '9223372036854775807',
      );
      expect(
        decoded.snapshot.records['ledger']!.single['delta'],
        '-9223372036854775808',
      );
      expect(decoded.preview.createdUtc, f.now);
      expect(
        decoded.snapshot.records['items']!.single['name'],
        'Synthetic 学习 🎮',
      );
    },
  );

  test('frozen independent v1 fixture retains every collection and canonical bytes', () {
    final file = BackupFile(
      File('test/data/fixtures/portable-v1.minutrove').readAsBytesSync(),
    );
    final decoded = codec.decode(file);
    expect(codec.encode(decoded.snapshot).bytes, file.bytes);
    expect(decoded.snapshot.records.keys, unorderedEquals(backupCollections));
    expect(
      decoded.snapshot.records.values.every((rows) => rows.isNotEmpty),
      true,
    );
    expect(
      decoded.snapshot.records['accrualRemainders']!.single['value'],
      '300000',
    );
    expect(
      (decoded.snapshot.records['awardBalances']!.single['budget']
          as Map)['minor'],
      '2250',
    );
    expect(decoded.snapshot.records['sessions']!.single['settled'], '300000');
  });

  test('every changed byte, truncation and trailing data fails closed', () {
    final file = codec.encode(snapshot());
    for (final index in [0, file.bytes.length ~/ 2, file.bytes.length - 1]) {
      final bytes = file.bytes.toList();
      bytes[index] ^= 1;
      expect(
        () => codec.decode(BackupFile(bytes)),
        throwsA(isA<InvalidBackup>()),
      );
    }
    for (final bytes in [
      file.bytes.sublist(0, file.bytes.length - 1),
      [...file.bytes, 32],
      [0xff, 0xfe],
    ]) {
      expect(
        () => codec.decode(BackupFile(bytes)),
        throwsA(isA<InvalidBackup>()),
      );
    }
  });

  test('rejects unsupported version without interpreting its payload', () {
    final root = jsonDecode(
      utf8.decode(codec.encode(snapshot()).bytes),
    ) as Map<String, dynamic>;
    root['version'] = 2;
    expect(
      () => codec.decode(_file(root)),
      throwsA(
        isA<UnsupportedBackupVersion>().having((e) => e.version, 'version', 2),
      ),
    );
  });

  test('rejects forged metadata, counts, runtime fields and malformed numbers even with new digest', () {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (p) => p['recordCounts']['wallet'] = 2,
      (p) => p['records']['wallet'][0]['balances']['coins'] = 1.5,
      (p) => p['records']['wallet'][0]['balances']['coins'] =
          '9223372036854775808',
      (p) => p['records']['wallet'][0]['balances']['coins'] = '01',
      (p) => p['records']['wallet'][0]['balances']['coins'] = '-0',
      (p) => p['records']['items'][0]['executablePath'] = '/tmp/do-not-run',
      (p) => p['records']['settings'][0]['credential'] = 'synthetic-secret',
      (p) => p['records']['settings'][0]['type'] = 'notification',
      (p) => p['records']['wallet'] = <Object?>[],
      (p) => p['createdUtc'] = 'not-a-date',
      (p) => p['sourceSchemaVersion'] = 0,
    ]) {
      final root = jsonDecode(
        utf8.decode(codec.encode(snapshot()).bytes),
      ) as Map<String, dynamic>;
      mutate(root['payload'] as Map<String, dynamic>);
      _resign(root);
      expect(() => codec.decode(_file(root)), throwsA(isA<InvalidBackup>()));
    }
  });

  test(
    'canonical form rejects duplicate object keys and alternate whitespace',
    () {
      final text = utf8.decode(codec.encode(snapshot()).bytes);
      for (final modified in [
        text.replaceFirst('"format":', '"format":"other","format":'),
        ' $text',
      ]) {
        expect(
          () => codec.decode(BackupFile(utf8.encode(modified))),
          throwsA(isA<InvalidBackup>()),
        );
      }
    },
  );

  test(
    'file, record, count and nesting limits apply during encode and decode',
    () {
      final s = snapshot();
      final file = codec.encode(s);
      for (final limits in [
        const BackupLimits(maxFileBytes: 100),
        const BackupLimits(maxRecordBytes: 20),
        const BackupLimits(maxRecords: 1),
      ]) {
        final bounded = BackupCodec(limits: limits);
        expect(() => bounded.encode(s), throwsA(isA<InvalidBackup>()));
        expect(() => bounded.decode(file), throwsA(isA<InvalidBackup>()));
      }
      final nested =
          '${List.filled(100, '[').join()}0${List.filled(100, ']').join()}';
      expect(
        () => codec.decode(BackupFile(utf8.encode(nested))),
        throwsA(isA<InvalidBackup>()),
      );
    },
  );

  test('live session rows cannot encode, but historical operation snapshots retain original status', () {
    final base = snapshot();
    final running = f.session(f.quest());
    final rows = {
      ...base.records,
      'sessions': [records.toJson(running)],
    };
    final invalid = BackupSnapshot(
      createdUtc: base.createdUtc,
      sourceSchemaVersion: base.sourceSchemaVersion,
      currencyMetadataVersion: base.currencyMetadataVersion,
      records: rows,
    );
    expect(() => codec.encode(invalid), throwsA(isA<InvalidBackup>()));
    final operation = records.toJson(f.operation(running));
    expect((operation['result'] as Map)['status'], 'running');
    expect((operation['result'] as Map).containsKey('deadline'), false);
    expect((operation['result'] as Map)['start'], {
      'type': 'instant',
      'utc': '${f.now.millisecondsSinceEpoch}',
    });
  });
}

Object? _ordered(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List) return value.map(_ordered).toList();
  return value;
}

BackupFile _file(Map<String, dynamic> root) =>
    BackupFile(utf8.encode(jsonEncode(_ordered(root))));

void _resign(Map<String, dynamic> root) {
  final bytes = utf8.encode(jsonEncode(_ordered(root['payload'])));
  root['integrity'] = {
    'algorithm': 'sha256',
    'payloadBytes': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  };
}
