import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/settings/settings.dart';

import '../support/settings_fakes.dart';

void main() {
  late FakeBackupRepository backup;
  late FakeSettingsRepository settings;
  late FakePicker picker;
  late FakeSharer sharer;
  var restored = 0;

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MinutroveApp(
        home: BackupScreen(
          backup: backup,
          settings: settings,
          picker: picker,
          sharer: sharer,
          onRestored: () async => restored++,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    backup = FakeBackupRepository();
    settings = FakeSettingsRepository(
      AppSettings(
        revision: Revision(1),
        reportingZone: ReportingZone('Etc/UTC'),
      ),
    );
    picker = FakePicker(() => Uint8List.fromList([1, 2, 3]));
    sharer = FakeSharer();
    restored = 0;
  });

  testWidgets('discloses the unencrypted property before any hand-off', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(find.text('Keep a copy'), findsOneWidget);
    expect(
      find.text('Backups contain your items, balances, history and settings.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Files are not encrypted. Anyone with the file can read your data.',
      ),
      findsOneWidget,
    );
    expect(sharer.shares, isEmpty);
  });

  testWidgets('export shares a .minutrove file with the exported bytes', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Export .minutrove file'));
    await tester.pumpAndSettle();
    expect(backup.exports, hasLength(1));
    expect(sharer.shares, hasLength(1));
    final (name, bytes) = sharer.shares.single;
    expect(name, endsWith('.minutrove'));
    expect(bytes, List.generate(16, (index) => index));
  });

  testWidgets('export during an active session explains and changes nothing', (
    tester,
  ) async {
    backup.exportResult = const Failure(ActiveSessionConflict());
    await pumpScreen(tester);
    await tester.tap(find.text('Export .minutrove file'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('End the current session before exporting'),
      findsOneWidget,
    );
    expect(sharer.shares, isEmpty);
  });

  testWidgets('cancelling the picker leaves everything untouched', (
    tester,
  ) async {
    picker = FakePicker(() => null);
    await pumpScreen(tester);
    await tester.tap(find.text('Choose a backup to restore'));
    await tester.pumpAndSettle();
    expect(backup.inspects, isEmpty);
    expect(backup.restores, isEmpty);
    expect(find.text('Replace current data?'), findsNothing);
  });

  testWidgets('validated file shows preview and requires explicit replace', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Choose a backup to restore'));
    await tester.pumpAndSettle();
    expect(backup.inspects, hasLength(1));
    expect(find.text('Replace current data?'), findsOneWidget);
    expect(
      find.textContaining(
        'This will replace the items, balances, history and settings',
      ),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(find.text('Cancel'), 100);
    expect(
      find.textContaining('12 items · 4 groups · 186 events'),
      findsOneWidget,
    );
    expect(find.textContaining('safety copy'), findsOneWidget);
    expect(find.textContaining('No timer will restart'), findsOneWidget);
    expect(backup.restores, isEmpty);
  });

  testWidgets('cancel after preview replaces nothing', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Choose a backup to restore'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Cancel'), 100);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backup.restores, isEmpty);
    expect(find.text('Replace current data?'), findsNothing);
  });

  testWidgets('replace restores with the digest-bound confirmation', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Choose a backup to restore'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace with this backup'));
    await tester.pumpAndSettle();
    expect(backup.restores, hasLength(1));
    final (operation, file, confirmation) = backup.restores.single;
    expect(operation.value, isNotEmpty);
    expect(file.bytes, [1, 2, 3]);
    expect(confirmation.preview.sha256, 'b' * 64);
    expect(confirmation.expectedSettingsRevision, Revision(1));
    expect(restored, 1);
    expect(find.text('Backup restored'), findsOneWidget);
  });

  testWidgets('newer backup version is rejected with data unchanged', (
    tester,
  ) async {
    backup.inspectResult = Failure<BackupPreview>(
      const UnsupportedBackupVersion(2),
    );
    await pumpScreen(tester);
    await tester.tap(find.text('Choose a backup to restore'));
    await tester.pumpAndSettle();
    expect(find.text('This file can’t be restored'), findsOneWidget);
    expect(find.textContaining('newer version of Minutrove'), findsOneWidget);
    expect(find.text('Your current data is unchanged.'), findsOneWidget);
    expect(backup.restores, isEmpty);
    await tester.tap(find.text('Back to settings'));
    await tester.pumpAndSettle();
    expect(backup.inspects, hasLength(1));
  });

  testWidgets('damaged file is rejected as invalid without mutation', (
    tester,
  ) async {
    backup.inspectResult = const Failure<BackupPreview>(
      InvalidBackup('Record validation failed'),
    );
    await pumpScreen(tester);
    await tester.tap(find.text('Choose a backup to restore'));
    await tester.pumpAndSettle();
    expect(find.text('This file can’t be restored'), findsOneWidget);
    expect(
      find.textContaining('damaged or not a Minutrove backup'),
      findsOneWidget,
    );
    expect(backup.restores, isEmpty);
  });

  testWidgets('replacement failure keeps the original data message', (
    tester,
  ) async {
    backup.restoreResult = const Failure<RestoreReceipt>(
      StorageUnavailable(retryable: true),
    );
    await pumpScreen(tester);
    await tester.tap(find.text('Choose a backup to restore'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace with this backup'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Your data is still safe'), findsOneWidget);
    expect(restored, 0);
    expect(find.text('Replace current data?'), findsNothing);
  });

  testWidgets('declined share explains without implying data loss', (
    tester,
  ) async {
    sharer.answer = const Success<bool>(false);
    await pumpScreen(tester);
    await tester.tap(find.text('Export .minutrove file'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sharing was not available'), findsOneWidget);
  });
}
