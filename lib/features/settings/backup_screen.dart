import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../platform/files/backup_files.dart';
import '../../ui/core/core.dart';
import '../items/items.dart' show randomUuid;

/// Manual backup export and validated restore. Export requires no active
/// session and is disclosed as unencrypted before the share sheet. Restore
/// always inspects into a temporary database first and replaces current data
/// only after the explicit in-app confirmation bound to that exact file.
class BackupScreen extends StatefulWidget {
  const BackupScreen({
    super.key,
    required this.backup,
    required this.settings,
    required this.picker,
    required this.sharer,
    this.onRestored,
    String Function()? backupFileName,
  }) : backupFileName = backupFileName ?? defaultBackupFileName;

  final BackupRepository backup;
  final SettingsRepository settings;
  final BackupFilePicker picker;
  final BackupFileSharer sharer;

  /// Called once after a successful replacement so the composition root can
  /// rebuild every repository on the reopened database.
  final Future<void> Function()? onRestored;

  final String Function() backupFileName;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

String defaultBackupFileName() {
  final now = DateTime.now();
  return 'minutrove-${now.year}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}.minutrove';
}

enum _RestoreStep { choose, inspecting, confirming, replacing, restored }

class _BackupScreenState extends State<BackupScreen> {
  _RestoreStep _restoreStep = _RestoreStep.choose;
  bool _exporting = false;
  String? _error;
  BackupFile? _picked;
  BackupPreview? _preview;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & restore')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(TroveTokens.pagePadding),
          children: [
            Semantics(
              header: true,
              child: Text('Keep a copy', style: TroveTokens.title),
            ),
            const SizedBox(height: 12),
            const Text(
              'Backups contain your items, balances, history and settings.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Files are not encrypted. Anyone with the file can read your data.',
            ),
            const SizedBox(height: 20),
            TroveButton(
              label: 'Export .minutrove file',
              onPressed: _exporting || _busy ? null : _export,
            ),
            const SizedBox(height: 8),
            TroveButton(
              label: 'Choose a backup to restore',
              secondary: true,
              onPressed: _busy ? null : _chooseRestoreFile,
            ),
            if (_error != null) ...[const SizedBox(height: 20), Text(_error!)],
            if (_restoreStep != _RestoreStep.choose) ...[
              const SizedBox(height: 24),
              ...switch (_restoreStep) {
                _RestoreStep.inspecting || _RestoreStep.replacing =>
                  const <Widget>[Center(child: TroveActivityIndicator())],
                _RestoreStep.confirming => _confirmPanel(),
                _RestoreStep.restored => <Widget>[
                  Semantics(
                    header: true,
                    child: Text('Backup restored', style: TroveTokens.heading),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Your data was replaced with the backup. No timer restarted.',
                  ),
                ],
                _RestoreStep.choose => const <Widget>[],
              },
            ],
            const SizedBox(height: 20),
            TroveButton(
              label: 'Back',
              secondary: true,
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  bool get _busy =>
      _exporting ||
      _restoreStep == _RestoreStep.inspecting ||
      _restoreStep == _RestoreStep.replacing;

  List<Widget> _confirmPanel() {
    final preview = _preview;
    if (preview == null) return const <Widget>[];
    return <Widget>[
      Semantics(
        header: true,
        child: Text('Replace current data?', style: TroveTokens.heading),
      ),
      const SizedBox(height: 8),
      const Text(
        'This will replace the items, balances, history and settings on this '
        'device.',
      ),
      const SizedBox(height: 12),
      Text(
        'Backup · ${backupCreatedLabel(preview.createdUtc)}\n'
        '${backupCountLabel(preview.recordCounts)}',
        style: TroveTokens.label,
      ),
      const SizedBox(height: 12),
      const Text(
        'A safety copy of your current data will be kept. No timer will restart.',
      ),
      const SizedBox(height: 20),
      TroveButton(label: 'Replace with this backup', onPressed: _replace),
      const SizedBox(height: 8),
      TroveButton(label: 'Cancel', secondary: true, onPressed: _cancelRestore),
    ];
  }

  Future<void> _export() async {
    setState(() {
      _exporting = true;
      _error = null;
    });
    final result = await widget.backup.exportBackup(
      operationId: OperationId(randomUuid()),
    );
    if (!mounted) return;
    switch (result) {
      case Success<BackupFile>(:final value):
        await _share(value);
      case Failure<BackupFile>(:final error):
        setState(() {
          _exporting = false;
          _error = switch (error) {
            ActiveSessionConflict() => 'End the current session before exporting. Paused sessions count too.',
            _ => 'Could not export a backup. Your data is unchanged.',
          };
        });
    }
  }

  Future<void> _share(BackupFile file) async {
    final shared = await widget.sharer.shareBackup(
      fileName: widget.backupFileName(),
      bytes: file.bytes,
    );
    if (!mounted) return;
    setState(() {
      _exporting = false;
      _error = switch (shared) {
        Success<bool>(:final value) =>
          value ? null : 'Sharing was not available. Your data is unchanged.',
        Failure<bool>() =>
          'Could not open the share sheet. Your data is unchanged.',
      };
    });
  }

  Future<void> _chooseRestoreFile() async {
    setState(() => _error = null);
    Uint8List bytes;
    try {
      final picked = await widget.picker.pickBackup();
      if (picked == null) return;
      bytes = picked;
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _error = 'Could not open the file picker. Try again in a moment.',
      );
      return;
    }
    if (!mounted) return;
    setState(() => _restoreStep = _RestoreStep.inspecting);
    BackupFile file;
    try {
      file = BackupFile(bytes);
    } on DomainError {
      _invalid('The file is damaged or not a Minutrove backup.');
      return;
    }
    final result = await widget.backup.inspectBackup(file);
    if (!mounted) return;
    switch (result) {
      case Success<BackupPreview>(:final value):
        setState(() {
          _picked = file;
          _preview = value;
          _restoreStep = _RestoreStep.confirming;
        });
      case Failure<BackupPreview>(:final error):
        _invalid(_invalidFileReason(error));
    }
  }

  void _invalid(String reason) {
    setState(() {
      _restoreStep = _RestoreStep.choose;
      _picked = null;
      _preview = null;
    });
    showDialog<void>(
      context: context,
      builder: (dialogContext) => TroveDialog(
        title: 'This file can’t be restored',
        actions: [
          TroveButton(
            label: 'Choose another file',
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _chooseRestoreFile();
            },
          ),
          TroveButton(
            label: 'Back to settings',
            secondary: true,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(reason),
            const SizedBox(height: 8),
            const Text('Your current data is unchanged.'),
          ],
        ),
      ),
    );
  }

  Future<void> _replace() async {
    final file = _picked;
    final preview = _preview;
    if (file == null || preview == null) return;
    final settings = await widget.settings.getSettings();
    final revision = switch (settings) {
      Success(:final value) => value.revision,
      Failure() => null,
    };
    if (revision == null) {
      setState(
        () => _error = 'Could not read your settings. Try the restore again.',
      );
      return;
    }
    setState(() => _restoreStep = _RestoreStep.replacing);
    final result = await widget.backup.restoreBackup(
      operationId: OperationId(randomUuid()),
      file: file,
      confirmation: RestoreConfirmation(
        preview: preview,
        expectedSettingsRevision: revision,
      ),
    );
    if (!mounted) return;
    switch (result) {
      case Success<RestoreReceipt>():
        await widget.onRestored?.call();
        if (!mounted) return;
        setState(() {
          _restoreStep = _RestoreStep.restored;
          _picked = null;
          _preview = null;
          _error = null;
        });
      case Failure<RestoreReceipt>(:final error):
        setState(() {
          _restoreStep = _RestoreStep.choose;
          _picked = null;
          _preview = null;
          _error = switch (error) {
            InvalidBackup() || UnsupportedBackupVersion() =>
              'This file can’t be restored. Your current data is unchanged.',
            StaleRevision() => 'Your settings changed during the restore. Check the backup again.',
            _ =>
              'Your data is still safe. The restore could not be completed. '
                  'Check free space, then try again.',
          };
        });
    }
  }

  void _cancelRestore() {
    // Cancellation is final for this file: nothing was replaced and the
    // picked bytes are dropped.
    setState(() {
      _restoreStep = _RestoreStep.choose;
      _picked = null;
      _preview = null;
    });
  }
}

/// Date label for the preview, shown in the reporting sense of the backup's
/// own creation instant.
String backupCreatedLabel(DateTime createdUtc) {
  final local = createdUtc.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

/// Human summary of the validated record counts, for example
/// "12 items · 4 groups · 186 events".
String backupCountLabel(Map<String, int> counts) {
  int count(String key) => counts[key] ?? 0;
  final parts = <String>[
    if (count('items') > 0) '${count('items')} items',
    if (count('groups') > 0) '${count('groups')} groups',
    if (count('ledger') > 0) '${count('ledger')} events',
  ];
  return parts.isEmpty ? 'No records' : parts.join(' · ');
}

String _invalidFileReason(DomainError error) => switch (error) {
  UnsupportedBackupVersion() => 'It was made by a newer version of Minutrove.',
  InvalidBackup() => 'The file is damaged or not a Minutrove backup.',
  StorageUnavailable() => 'The file could not be read. Try again in a moment.',
  _ => 'The file could not be validated as a Minutrove backup.',
};
