# Backup file picker and share sheet

`MethodChannelBackupFiles` implements the `BackupFilePicker` and
`BackupFileSharer` interfaces over the method channel
`io.github.vanzeph.minutrove/files`, backed by `BackupFiles.swift`
(`UIDocumentPickerViewController` / `UIActivityViewController`) on iOS and
`BackupFiles.kt` (`ACTION_OPEN_DOCUMENT` through the classic
startActivityForResult round trip, and `ACTION_SEND` through the embedded
`FileProvider`) on Android.

## Adapter contract

`pickBackup` opens the system document picker for one `.minutrove` backup.
Cancelling the picker answers null; no file is read and nothing changes. A
selected file is read once and answered as bytes. Any transport or platform
failure throws the retryable typed `StorageUnavailable`; platform details
never leave the adapter.

`shareBackup` writes the immutable export bytes to an OS-owned temporary
location only for the hand-off and opens the system share sheet. It answers
whether the sheet accepted the hand-off; sharing is a separate UI action from
export and never mutates stored data.

Both operations are user-driven UI, so they carry no timeout: the user may
hold the picker or sheet open for any length of time.

```dart
const files = MethodChannelBackupFiles();  // one per app lifetime
final picked = await files.pickBackup();   // null when cancelled
final shared = await files.shareBackup(
  fileName: 'minutrove-2026-09-14.minutrove',
  bytes: file.bytes,
);
```

Validation:

```sh
flutter test test/platform/backup_files_test.dart
```
