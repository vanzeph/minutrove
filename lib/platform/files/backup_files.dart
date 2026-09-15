import 'package:flutter/services.dart';

import '../../domain/domain.dart';

/// OS file access for manual backup transfer. Both operations are user-driven
/// UI, so they carry no timeout: the user may hold the picker or share sheet
/// open for any length of time before deciding.
abstract interface class BackupFilePicker {
  /// Opens the system document picker for one `.minutrove` file. Returns the
  /// selected file's bytes, or null when the user cancelled; nothing is read
  /// or changed on cancellation.
  Future<Uint8List?> pickBackup();
}

abstract interface class BackupFileSharer {
  /// Hands one exported backup to the system share sheet. The bytes are
  /// written to a temporary OS-owned location only for the share; the value
  /// answers whether the sheet accepted the hand-off.
  Future<Result<bool>> shareBackup({
    required String fileName,
    required Uint8List bytes,
  });
}

/// Method-channel adapter over `BackupFiles.swift` and `BackupFiles.kt`.
/// Cancellation is the expected null answer, not an error; any transport or
/// platform failure becomes the retryable typed `StorageUnavailable` so
/// platform details never reach feature callers.
final class MethodChannelBackupFiles
    implements BackupFilePicker, BackupFileSharer {
  const MethodChannelBackupFiles({
    this.channel = const MethodChannel(channelName),
  });

  static const channelName = 'io.github.vanzeph.minutrove/files';

  final MethodChannel channel;

  @override
  Future<Uint8List?> pickBackup() async {
    try {
      final bytes = await channel.invokeMethod<List<Object?>>('pickBackup');
      if (bytes == null) return null;
      return Uint8List.fromList(bytes.cast<int>());
    } on PlatformException catch (error) {
      if (error.code == 'pick_cancelled') return null;
      throw const StorageUnavailable(retryable: true);
    }
  }

  @override
  Future<Result<bool>> shareBackup({
    required String fileName,
    required Uint8List bytes,
  }) async {
    try {
      final shared = await channel.invokeMethod<bool>('shareBackup', {
        'fileName': fileName,
        'bytes': bytes,
      });
      return Success(shared ?? false);
    } on PlatformException {
      return const Failure(StorageUnavailable(retryable: true));
    }
  }
}
