import 'package:flutter/material.dart';

import '../../../domain/domain.dart';
import '../../../ui/core/core.dart';
import '../../items/items.dart' show randomUuid;
import '../timezone_screen.dart';

/// Concise first-run onboarding. It is optional at every step, creates no
/// sample items and embeds no hardcoded goals, prices or durations: the
/// user's own Quests and Awards are configured after onboarding on Home.
///
/// The stored reporting timezone is shown with its day-boundary meaning and
/// can be corrected here once; skipping writes nothing. Notifications are
/// asked for contextually, and a denied answer links to the system settings.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({
    super.key,
    required this.settings,
    required this.notifications,
    required this.onFinished,
  });

  final SettingsRepository settings;
  final NotificationScheduler notifications;

  /// Completion callback: both finishing and skipping end onboarding. The
  /// composition root decides whether to show this flow again.
  final VoidCallback onFinished;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

enum _OnboardingStep { welcome, timezone, notifications }

class _OnboardingFlowState extends State<OnboardingFlow> {
  _OnboardingStep _step = _OnboardingStep.welcome;
  AppSettings? _settings;
  ReportingZone? _zone;
  NotificationPermission? _permission;
  bool _asking = false;
  bool _savingZone = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await widget.settings.getSettings();
    if (!mounted) return;
    switch (result) {
      case Success<AppSettings>(:final value):
        setState(() {
          _settings = value;
          _zone = value.reportingZone;
        });
      case Failure<AppSettings>():
        setState(() => _error = 'Could not load your settings.');
    }
    try {
      final permission = await widget.notifications.permission();
      if (!mounted) return;
      setState(() => _permission = permission);
    } catch (_) {
      // Permission status is optional context; the contextual ask still runs.
    }
  }

  void _skip() => widget.onFinished();

  Future<void> _finish() async => widget.onFinished();

  /// Continues from the timezone step, persisting an explicitly changed zone
  /// once before advancing; everything else on this flow writes nothing.
  Future<void> _continueFromTimezone() async {
    final changed = _zoneChanged;
    if (changed && _zone != null && _settings != null && !_savingZone) {
      setState(() {
        _savingZone = true;
        _error = null;
      });
      final result = await widget.settings.saveSettings(
        operationId: OperationId(randomUuid()),
        expectedRevision: _settings!.revision,
        reportingZone: _zone!,
      );
      if (!mounted) return;
      switch (result) {
        case Success<AppSettings>():
          setState(() {
            _savingZone = false;
            _step = _OnboardingStep.notifications;
          });
        case Failure<AppSettings>(:final error):
          setState(() {
            _savingZone = false;
            _error = 'Could not save your timezone. ${settingsError(error)}';
          });
      }
      return;
    }
    setState(() => _step = _OnboardingStep.notifications);
  }

  Future<void> _askNotifications() async {
    if (_asking) return;
    setState(() => _asking = true);
    try {
      final permission = await widget.notifications.requestPermission(
        operationId: OperationId(randomUuid()),
      );
      if (!mounted) return;
      setState(() => _permission = permission);
    } catch (_) {
      if (!mounted) return;
      setState(() => _permission = NotificationPermission.denied);
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  Future<void> _openSystemSettings() async {
    await widget.notifications.openSystemSettings(
      operationId: OperationId(randomUuid()),
    );
  }

  Future<void> _pickZone() async {
    final zone = _zone;
    if (zone == null) return;
    final selected = await showTroveDialog<ReportingZone>(
      context: context,
      title: 'Reporting timezone',
      builder: (dialogContext) => ZonePickerDialog(selected: zone),
    );
    if (selected != null) setState(() => _zone = selected);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(TroveTokens.pagePadding),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: switch (_step) {
                _OnboardingStep.welcome => _welcome(),
                _OnboardingStep.timezone => _timezone(),
                _OnboardingStep.notifications => _notifications(),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _welcome() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(
        header: true,
        child: Text('Turn your time into treasure', style: TroveTokens.title),
      ),
      const SizedBox(height: 12),
      const Text(
        'Minutrove is yours to define. Create Quests that earn Coins and Gems '
        'from active time, then redeem them for Awards you choose.',
      ),
      const SizedBox(height: 8),
      const Text(
        'Everything stays on this device. There is no account and no cloud '
        'service.',
      ),
      const SizedBox(height: 20),
      TroveButton(
        label: 'Get started',
        onPressed: () => setState(() => _step = _OnboardingStep.timezone),
      ),
      const SizedBox(height: 8),
      TroveButton(label: 'Skip setup', secondary: true, onPressed: _skip),
    ],
  );

  Widget _timezone() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(
        header: true,
        child: Text('Your reporting day', style: TroveTokens.title),
      ),
      const SizedBox(height: 12),
      const Text(
        'Daily goals and charts follow one reporting timezone. Travel won’t '
        'change it automatically.',
      ),
      const SizedBox(height: 20),
      if (_zone != null)
        Semantics(
          button: true,
          onTap: _pickZone,
          child: OutlinedButton(
            onPressed: _pickZone,
            child: Text(_zone!.ianaName),
          ),
        ),
      if (_error != null) ...[const SizedBox(height: 12), Text(_error!)],
      const SizedBox(height: 20),
      TroveButton(
        label: _zoneChanged ? 'Save timezone and continue' : 'Continue',
        onPressed: _savingZone ? null : _continueFromTimezone,
      ),
      const SizedBox(height: 8),
      TroveButton(
        label: 'Skip setup',
        secondary: true,
        onPressed: _savingZone ? null : _skip,
      ),
    ],
  );

  Widget _notifications() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(
        header: true,
        child: Text('Finish on your terms', style: TroveTokens.title),
      ),
      const SizedBox(height: 12),
      const Text(
        'Minutrove can ring a short chime when a session finishes. Sessions '
        'still finish on time if you skip this.',
      ),
      const SizedBox(height: 8),
      switch (_permission) {
        NotificationPermission.denied || NotificationPermission.restricted =>
          const Text('Notifications are turned off for Minutrove.'),
        _ => const SizedBox.shrink(),
      },
      const SizedBox(height: 20),
      switch (_permission) {
        NotificationPermission.denied ||
        NotificationPermission.restricted => TroveButton(
          label: 'Open system settings',
          secondary: true,
          onPressed: _openSystemSettings,
        ),
        NotificationPermission.granted => const SizedBox.shrink(),
        _ => TroveButton(
          label: 'Allow notifications',
          onPressed: _asking ? null : _askNotifications,
        ),
      },
      const SizedBox(height: 8),
      TroveButton(label: 'Done', onPressed: _finish),
      const SizedBox(height: 8),
      TroveButton(label: 'Skip setup', secondary: true, onPressed: _skip),
    ],
  );

  bool get _zoneChanged =>
      _settings != null && _zone != _settings!.reportingZone;
}
