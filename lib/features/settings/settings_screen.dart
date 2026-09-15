import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../platform/files/backup_files.dart';
import '../../ui/core/core.dart';
import 'about_screen.dart';
import 'backup_screen.dart';
import 'notifications_screen.dart';
import 'timezone_screen.dart';

/// Settings overview. Local-only storage is stated up front; every entry is
/// a plain navigation action, so cancelling any sub-screen changes nothing.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.notifications,
    required this.backup,
    required this.picker,
    required this.sharer,
    this.onRestored,
  });

  final SettingsRepository settings;
  final NotificationScheduler notifications;
  final BackupRepository backup;
  final BackupFilePicker picker;
  final BackupFileSharer sharer;

  /// Passed to the backup screen so a successful replacement can rebuild
  /// repositories on the reopened database.
  final Future<void> Function()? onRestored;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(TroveTokens.pagePadding),
          children: [
            Semantics(
              header: true,
              child: Text('Your Minutrove', style: TroveTokens.title),
            ),
            const SizedBox(height: 12),
            const Text(
              'Local to this device. Backups let you move your data manually.',
            ),
            const SizedBox(height: 20),
            TroveButton(
              label: 'Backup & restore',
              onPressed: () => _push(
                context,
                BackupScreen(
                  backup: backup,
                  settings: settings,
                  picker: picker,
                  sharer: sharer,
                  onRestored: onRestored,
                ),
              ),
            ),
            const SizedBox(height: 8),
            TroveButton(
              label: 'Reporting timezone',
              secondary: true,
              onPressed: () =>
                  _push(context, TimezoneScreen(settings: settings)),
            ),
            const SizedBox(height: 8),
            TroveButton(
              label: 'Notifications & sound',
              secondary: true,
              onPressed: () => _push(
                context,
                NotificationsScreen(notifications: notifications),
              ),
            ),
            const SizedBox(height: 8),
            TroveButton(
              label: 'About & licenses',
              secondary: true,
              onPressed: () => _push(context, const AboutScreen()),
            ),
          ],
        ),
      ),
    );
  }

  void _push(BuildContext context, Widget screen) =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => screen));
}
