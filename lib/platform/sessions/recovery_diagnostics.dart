import 'dart:io';

/// Fixed local event codes only: no IDs, amounts, names or raw clock readings.
enum RecoveryDiagnostic {
  bootChanged,
  wallClockForward,
  wallClockBackward,
  recoveryUnavailable,
}

typedef RecordRecoveryDiagnostic = Future<void> Function(RecoveryDiagnostic);

/// A bounded, best-effort log next to the private database, excluded from backup.
/// Logging cannot change whether a committed economic command succeeded.
final class LocalRecoveryDiagnostics {
  LocalRecoveryDiagnostics(this.file);
  final File file;
  Future<void> _tail = Future.value();

  Future<void> record(RecoveryDiagnostic event) {
    final next = _tail.then((_) async {
      try {
        var codes = <String>[];
        if (await file.exists() && await file.length() <= 8192) {
          final allowed = RecoveryDiagnostic.values.map((e) => e.name).toSet();
          codes = (await file.readAsLines()).where(allowed.contains).toList();
        }
        codes.add(event.name);
        if (codes.length > 32) codes = codes.sublist(codes.length - 32);
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString('${codes.join('\n')}\n', flush: true);
        await temporary.rename(file.path);
      } catch (_) {
        // A full/unavailable diagnostic directory never fails session recovery.
      }
    });
    _tail = next;
    return next;
  }
}
