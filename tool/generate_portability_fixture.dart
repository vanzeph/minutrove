import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test/support/backup_portability.dart' as p;

/// Regenerates the committed cross-platform reference fixture
/// (test/data/fixtures/portability-v1.minutrove) from the deterministic
/// portability history, using the pinned toolchain on the host:
///
///   flutter pub get --enforce-lockfile
///   dart run tool/generate_portability_fixture.dart
///
/// The bytes are platform-independent by construction; iOS/Android/host
/// exports must all reproduce them exactly. After regenerating, copy the
/// printed SHA-256 into portabilityReferenceSha256 and update
/// docs/backup-portability.md.
Future<void> main(List<String> arguments) async {
  sqfliteFfiInit();
  final output = arguments.isNotEmpty
      ? arguments.first
      : p.portabilityReferencePath;
  final directory = await Directory.systemTemp.createTemp(
    'minutrove-portability-gen-',
  );
  final world = await p.buildPortabilityHistory(
    path: '${directory.path}/data.sqlite',
    factory: databaseFactoryFfi,
  );
  try {
    final file = await world.export();
    await File(output).writeAsBytes(file.bytes, flush: true);
    final coverage = await p.portabilityCoverage(file);
    final state = await p.portabilityDomainState(world.store);
    stdout.writeln('wrote $output (${file.bytes.length} bytes)');
    stdout.writeln('sha256: ${coverage['sha256']}');
    stdout.writeln('createdUtc: ${coverage['createdUtc']}');
    stdout.writeln('recordCounts: ${coverage['recordCounts']}');
    stdout.writeln('ledgerYears: ${coverage['years']}');
    stdout.writeln('budgetPrecisions: ${coverage['budgetPrecisions']}');
    stdout.writeln('archived: ${coverage['archived']}');
    stdout.writeln('achievements: ${coverage['achievements']}');
    stdout.writeln('remaindersNonZero: ${coverage['remaindersNonZero']}');
    stdout.writeln('wallet: ${state['wallet']}');
  } finally {
    await world.close();
    await directory.delete(recursive: true);
  }
}
