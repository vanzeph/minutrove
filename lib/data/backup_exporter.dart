import '../domain/domain.dart';
import 'backup_codec.dart';
import 'sqlite_store.dart';

/// Export half of BackupRepository, composed by the restore adapter when ready.
/// No file picker, sharing, mutation, notification action or restore stub here.
final class SqliteBackupExporter {
  const SqliteBackupExporter({
    required this.store,
    required this.clock,
    this.codec = const BackupCodec(),
  });
  final SqliteStore store;
  final Clock clock;
  final BackupCodec codec;

  /// Export is a read: operationId does not reserve a durable command or cache a
  /// growing backup inside itself. Same snapshot/date gives identical bytes;
  /// retry obtains the current committed snapshot, checking the slot again.
  Future<Result<BackupFile>> exportBackup({
    required OperationId operationId,
  }) async {
    final result = await store.read((records) async {
      try {
        final snapshot = await records.backupSnapshot(
          createdUtc: () async => (await clock.now()).utc,
          limits: codec.limits,
        );
        // Keep size validation/encoding in this same queued read operation.
        return Success(codec.encode(snapshot));
      } on ActiveSessionConflict catch (error) {
        return Failure<BackupFile>(error);
      } on InvalidBackup catch (error) {
        return Failure<BackupFile>(error);
      }
    });
    return switch (result) {
      Success(:final value) => value,
      Failure(:final error) => Failure(error),
    };
  }
}
