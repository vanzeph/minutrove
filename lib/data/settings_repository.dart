import '../domain/domain.dart';
import 'command_coordinator.dart';
import 'sqlite_store.dart';

/// Settings apply prospectively. Existing sessions and frozen history are never
/// rewritten, including when the current session is paused during a zone edit.
final class SqliteSettingsRepository implements SettingsRepository {
  const SqliteSettingsRepository({
    required this.store,
    required this.clock,
    required this.calendar,
  });
  final SqliteStore store;
  final Clock clock;
  final ReportingCalendar calendar;

  @override
  Future<Result<AppSettings>> getSettings() => store.read((r) => r.settings());

  @override
  Future<Result<AppSettings>> saveSettings({
    required OperationId operationId,
    required Revision expectedRevision,
    required ReportingZone reportingZone,
  }) => CommandCoordinator(store).execute(
    operationId: operationId,
    request: CommandRequest(
      kind: OperationKind.saveSettings,
      arguments: {
        'expectedRevision': expectedRevision.value,
        'reportingZone': reportingZone.ianaName,
      },
    ),
    committedAt: (_) async {
      if (!calendar.supports(reportingZone)) {
        throw const InvalidInput('reportingZone', 'Unsupported IANA zone');
      }
      return calendar.assign((await clock.now()).utc, reportingZone);
    },
    action: (command) async {
      final current = await command.records.settings();
      if (current.revision != expectedRevision) throw const StaleRevision();
      final saved = AppSettings(
        revision: current.revision.next(),
        reportingZone: reportingZone,
      );
      await command.records.putSettings(saved);
      return saved;
    },
  );
}
