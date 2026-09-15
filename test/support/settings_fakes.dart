import 'dart:typed_data';

import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/platform/files/backup_files.dart';

/// Recording fakes for the settings, onboarding and backup screens. They
/// answer configured results and record every call so widget tests can
/// assert exactly which commands a user journey issued.
final class FakeSettingsRepository implements SettingsRepository {
  FakeSettingsRepository(this._settings);

  AppSettings _settings;
  final saves = <(OperationId, Revision, ReportingZone)>[];
  DomainError? failWith;

  /// Current stored settings, for asserting state after a journey.
  AppSettings get current => _settings;

  /// Simulates a concurrent settings edit that invalidates a loaded revision.
  void bumpRevision() {
    _settings = AppSettings(
      revision: Revision(_settings.revision.value + 1),
      reportingZone: _settings.reportingZone,
    );
  }

  @override
  Future<Result<AppSettings>> getSettings() async =>
      failWith == null ? Success(_settings) : Failure<AppSettings>(failWith!);

  @override
  Future<Result<AppSettings>> saveSettings({
    required OperationId operationId,
    required Revision expectedRevision,
    required ReportingZone reportingZone,
  }) async {
    if (failWith != null) return Failure<AppSettings>(failWith!);
    saves.add((operationId, expectedRevision, reportingZone));
    if (expectedRevision != _settings.revision) {
      return const Failure<AppSettings>(StaleRevision());
    }
    _settings = AppSettings(
      revision: Revision(_settings.revision.value + 1),
      reportingZone: reportingZone,
    );
    return Success(_settings);
  }
}

final class FakeNotificationScheduler implements NotificationScheduler {
  FakeNotificationScheduler({
    this.status = NotificationPermission.notDetermined,
  });

  NotificationPermission status;
  NotificationPermission? nextPermission;
  final requests = <OperationId>[];
  final settingsRequests = <OperationId>[];
  Object Function()? throwOnPermission;
  bool failOpenSettings = false;

  @override
  Future<NotificationPermission> permission() async {
    final failure = throwOnPermission;
    if (failure != null) throw failure();
    return status;
  }

  @override
  Future<NotificationPermission> requestPermission({
    required OperationId operationId,
  }) async {
    requests.add(operationId);
    final answered = nextPermission ?? status;
    status = answered;
    return answered;
  }

  @override
  Future<Result<NotificationPermission>> reconcile({
    required OperationId operationId,
    required List<NotificationIntent> intents,
  }) async => Success(status);

  @override
  Future<Result<bool>> openSystemSettings({
    required OperationId operationId,
  }) async {
    settingsRequests.add(operationId);
    return failOpenSettings
        ? const Failure(StorageUnavailable(retryable: true))
        : const Success<bool>(true);
  }
}

final class FakeBackupRepository implements BackupRepository {
  Result<BackupFile> exportResult = Success(
    BackupFile(List.generate(16, (index) => index)),
  );
  Result<BackupPreview> inspectResult = Success(preview());
  Result<RestoreReceipt> restoreResult = Success(
    RestoreReceipt(
      operationId: OperationId('00000000-0000-4000-8000-00000000aaa1'),
      sourceSha256: 'a' * 64,
      schemaVersion: SchemaVersion(1),
      settings: AppSettings(
        revision: Revision(1),
        reportingZone: ReportingZone('Etc/UTC'),
      ),
    ),
  );

  final exports = <OperationId>[];
  final inspects = <BackupFile>[];
  final restores = <(OperationId, BackupFile, RestoreConfirmation)>[];

  @override
  Future<Result<BackupFile>> exportBackup({
    required OperationId operationId,
  }) async {
    exports.add(operationId);
    return exportResult;
  }

  @override
  Future<Result<BackupPreview>> inspectBackup(BackupFile file) async {
    inspects.add(file);
    return inspectResult;
  }

  @override
  Future<Result<RestoreReceipt>> restoreBackup({
    required OperationId operationId,
    required BackupFile file,
    required RestoreConfirmation confirmation,
  }) async {
    restores.add((operationId, file, confirmation));
    return restoreResult;
  }
}

BackupPreview preview({DateTime? createdUtc, Map<String, int>? counts}) =>
    BackupPreview(
      version: BackupVersion(1),
      createdUtc: createdUtc ?? DateTime.utc(2026, 9, 5, 18, 30),
      sha256: 'b' * 64,
      recordCounts:
          counts ??
          {
            'groups': 4,
            'items': 12,
            'itemRevisions': 20,
            'sessions': 40,
            'operations': 120,
            'ledger': 186,
            'wallet': 1,
            'awardBalances': 3,
            'accrualRemainders': 2,
            'goalRevisions': 5,
            'achievements': 6,
            'settings': 1,
          },
    );

final class FakePicker implements BackupFilePicker {
  FakePicker(this.next);
  final Uint8List? Function() next;
  final calls = <void>[];

  @override
  Future<Uint8List?> pickBackup() async {
    calls.add(null);
    return next();
  }
}

final class FakeSharer implements BackupFileSharer {
  Result<bool> answer = const Success<bool>(true);
  final shares = <(String, Uint8List)>[];

  @override
  Future<Result<bool>> shareBackup({
    required String fileName,
    required Uint8List bytes,
  }) async {
    shares.add((fileName, bytes));
    return answer;
  }
}
