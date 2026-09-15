import 'package:flutter/material.dart';
import 'package:timezone/data/latest_all.dart' as data;
import 'package:timezone/timezone.dart' as tz;

import '../../domain/domain.dart';
import '../../ui/core/core.dart';
import '../items/items.dart' show randomUuid;

/// Reporting-timezone editing. Changes apply prospectively to new sessions
/// and operations; earlier activity keeps its original dates because every
/// ledger row froze its day assignment when it happened.
class TimezoneScreen extends StatefulWidget {
  const TimezoneScreen({super.key, required this.settings});

  final SettingsRepository settings;

  @override
  State<TimezoneScreen> createState() => _TimezoneScreenState();
}

class _TimezoneScreenState extends State<TimezoneScreen> {
  AppSettings? _current;
  ReportingZone? _selected;
  String? _error;
  bool _saving = false;
  bool _loaded = true;

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
          _current = value;
          _selected = value.reportingZone;
          _error = null;
          _loaded = true;
        });
      case Failure<AppSettings>(:final error):
        setState(() {
          _error = 'Could not load your settings. ${settingsError(error)}';
          _loaded = false;
        });
    }
  }

  Future<void> _save() async {
    final current = _current;
    final selected = _selected;
    if (current == null ||
        selected == null ||
        selected == current.reportingZone) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    final result = await widget.settings.saveSettings(
      operationId: OperationId(randomUuid()),
      expectedRevision: current.revision,
      reportingZone: selected,
    );
    if (!mounted) return;
    switch (result) {
      case Success<AppSettings>():
        Navigator.of(context).pop(true);
      case Failure<AppSettings>(:final error):
        setState(() {
          _saving = false;
          _error = switch (error) {
            StaleRevision() => 'Your settings changed elsewhere. Reload the latest version before saving.',
            _ => 'Could not save your timezone. ${settingsError(error)}',
          };
        });
    }
  }

  Future<void> _pickZone() async {
    final current = _selected;
    if (current == null) return;
    final zone = await showTroveDialog<ReportingZone>(
      context: context,
      title: 'Reporting timezone',
      builder: (dialogContext) => ZonePickerDialog(selected: current),
    );
    if (zone != null) setState(() => _selected = zone);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final changed = selected != null && selected != _current?.reportingZone;
    return Scaffold(
      appBar: AppBar(title: const Text('Reporting timezone')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(TroveTokens.pagePadding),
          children: [
            Semantics(
              header: true,
              child: Text('Your reporting day', style: TroveTokens.title),
            ),
            const SizedBox(height: 12),
            const Text(
              'Travel won’t change your reporting timezone automatically.',
            ),
            const SizedBox(height: 20),
            if (_error != null) ...[
              Text(_error!),
              if (!_loaded)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TroveButton(label: 'Retry loading', onPressed: _load),
                ),
              const SizedBox(height: 20),
            ],
            if (selected != null)
              Semantics(
                button: true,
                onTap: _pickZone,
                child: OutlinedButton(
                  onPressed: _pickZone,
                  child: Text(selected.ianaName),
                ),
              ),
            const SizedBox(height: 20),
            const Text(
              'Changes apply to new sessions and operations. Earlier activity '
              'stays on its original dates.',
            ),
            const SizedBox(height: 20),
            TroveButton(
              label: 'Save timezone',
              onPressed: _saving || !changed ? null : _save,
            ),
            const SizedBox(height: 8),
            TroveButton(
              label: 'Cancel',
              secondary: true,
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Searchable IANA catalog from the locked offline timezone database; the
/// repository revalidates membership inside the save transaction.
class ZonePickerDialog extends StatefulWidget {
  const ZonePickerDialog({super.key, required this.selected});
  final ReportingZone selected;

  @override
  State<ZonePickerDialog> createState() => _ZonePickerDialogState();
}

class _ZonePickerDialogState extends State<ZonePickerDialog> {
  final _search = TextEditingController();
  List<String>? _zones;

  @override
  void initState() {
    super.initState();
    _zones = ianaZoneCatalog();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zones = _zones ?? const <String>[];
    final query = _search.text.trim().toLowerCase();
    final matches = query.isEmpty
        ? zones
        : zones.where((zone) => zone.toLowerCase().contains(query)).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TroveTextField(
          label: 'Search timezones',
          controller: _search,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: matches.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No timezone matches your search.'),
                )
              : Scrollbar(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: matches.length,
                    itemBuilder: (context, index) {
                      final zone = matches[index];
                      return ListTile(
                        title: Text(zone),
                        trailing: zone == widget.selected.ianaName
                            ? const Icon(Icons.check, size: 20)
                            : null,
                        onTap: () =>
                            Navigator.of(context).pop(ReportingZone(zone)),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

List<String> ianaZoneCatalog() {
  data.initializeTimeZones();
  final zones = tz.timeZoneDatabase.locations.keys.toList()..sort();
  return zones;
}

String settingsError(DomainError error) => switch (error) {
  StaleRevision() =>
    'Your settings changed elsewhere. Reload the latest version before saving.',
  InvalidInput() => 'That timezone is not supported.',
  StorageUnavailable() =>
    'Local storage is unavailable right now. Try again in a moment.',
  _ => 'The change could not be saved.',
};
