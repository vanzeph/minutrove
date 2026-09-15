import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../ui/core/core.dart';
import '../items/items.dart' show randomUuid;

/// Notification permission status with the contextual ask and the
/// system-settings action for a denied decision. Sessions always settle on
/// their deadline; delivery and audibility remain subject to OS policy.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key, required this.notifications});

  final NotificationScheduler notifications;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

enum _PermissionLoad { loading, failed, ready }

class _NotificationsScreenState extends State<NotificationsScreen> {
  _PermissionLoad _load = _PermissionLoad.loading;
  NotificationPermission? _permission;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _load = _PermissionLoad.loading);
    try {
      final permission = await widget.notifications.permission();
      if (!mounted) return;
      setState(() {
        _permission = permission;
        _load = _PermissionLoad.ready;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _load = _PermissionLoad.failed);
    }
  }

  Future<void> _ask() async {
    if (_asking) return;
    setState(() => _asking = true);
    try {
      final permission = await widget.notifications.requestPermission(
        operationId: OperationId(randomUuid()),
      );
      if (!mounted) return;
      setState(() {
        _permission = permission;
        _asking = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _asking = false);
    }
  }

  Future<void> _openSystemSettings() async {
    await widget.notifications.openSystemSettings(
      operationId: OperationId(randomUuid()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final permission = _permission;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications & sound')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(TroveTokens.pagePadding),
          children: [
            Semantics(
              header: true,
              child: Text('Finish on your terms', style: TroveTokens.title),
            ),
            const SizedBox(height: 12),
            ...switch (_load) {
              _PermissionLoad.loading => <Widget>[
                const Center(child: TroveActivityIndicator()),
              ],
              _PermissionLoad.failed => <Widget>[
                const Text('Could not read the notification status.'),
                const SizedBox(height: 20),
                TroveButton(label: 'Retry loading', onPressed: _refresh),
              ],
              _PermissionLoad.ready => <Widget>[
                switch (permission) {
                  NotificationPermission.granted => const Text(
                    'Notifications are on for Minutrove.',
                  ),
                  NotificationPermission.notDetermined => const Text(
                    'Minutrove can ring a short chime when a session finishes.',
                  ),
                  NotificationPermission.denied ||
                  NotificationPermission.restricted => const Text(
                    'Notifications are turned off for Minutrove.',
                  ),
                  null => const SizedBox.shrink(),
                },
                const SizedBox(height: 12),
                const Text(
                  'Sessions still finish on time. Alerts and sound may be '
                  'suppressed by system permissions, silent mode or Focus.',
                ),
                const SizedBox(height: 20),
                switch (permission) {
                  NotificationPermission.granted => const SizedBox.shrink(),
                  NotificationPermission.notDetermined => TroveButton(
                    label: 'Allow notifications',
                    onPressed: _asking ? null : _ask,
                  ),
                  NotificationPermission.denied ||
                  NotificationPermission.restricted => TroveButton(
                    label: 'Open system settings',
                    secondary: true,
                    onPressed: _openSystemSettings,
                  ),
                  null => const SizedBox.shrink(),
                },
              ],
            },
            const SizedBox(height: 20),
            TroveButton(
              label: 'Back',
              secondary: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
