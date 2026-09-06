// Real subprocess fixture: all inputs and output are synthetic. The parent
// kills this process after the acknowledgement, without closing the database.
import 'dart:convert';
import 'dart:io';

import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/platform/sessions/recovery_diagnostics.dart';
import 'package:minutrove/platform/sessions/session_recovery.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/support.dart' as f;
import 'session_fixtures.dart';

Future<void> main(List<String> args) async {
  sqfliteFfiInit();
  final [path, mode, wall, mono, boot, operation] = args;
  final clock = SessionClock()
    ..utc = DateTime.fromMillisecondsSinceEpoch(int.parse(wall), isUtc: true)
    ..monotonic = int.parse(mono)
    ..boot = boot;
  final store = f.success(
    await SqliteStore.open(
      path: path,
      factory: databaseFactoryFfi,
      currencies: f.metadata,
      initialSettings: f.settings,
    ),
  );
  final calendar = SessionCalendar();
  final repo = SqliteSessionRepository(
    store: store,
    clock: clock,
    calendar: calendar,
  );
  final id = OperationId(f.uuid(int.parse(operation)));
  Session? session;
  if (mode == 'start') {
    final item = f.success(
      await SqliteItemRepository(
        store: store,
        clock: clock,
        calendar: calendar,
      ).saveItem(
        operationId: OperationId(f.uuid(100)),
        item: f.quest(),
        expectedRevision: null,
      ),
    );
    session = f
        .success(
          await repo.startSession(
            operationId: id,
            itemId: item.id,
            expectedItemRevision: item.revision,
            conflictChoice: SessionConflictChoice.cancel,
          ),
        )
        .session;
  } else {
    final current = f.success(
      await store.read((r) => r.session(SessionId(f.uuid(101)))),
    )!;
    switch (mode) {
      case 'pause':
        session = f
            .success(
              await repo.pauseSession(
                operationId: id,
                sessionId: current.id,
                expectedRevision: current.revision,
              ),
            )
            .session;
      case 'resume':
        session = f
            .success(
              await repo.resumeSession(
                operationId: id,
                sessionId: current.id,
                expectedRevision: current.revision,
              ),
            )
            .session;
      case 'replay':
        clock.unavailable = true;
        session = f
            .success(
              await repo.reconcileSession(
                operationId: id,
                sessionId: current.id,
              ),
            )
            .session;
      case 'recover':
        final recovery = SessionRecovery(
          store: store,
          sessions: repo,
          recordDiagnostic: LocalRecoveryDiagnostics(File('$path.diagnostics'))
              .record,
        );
        f.success(await recovery.reconcile(operationId: id));
        session = f.success(await repo.getSession(current.id));
      default:
        throw StateError('Unknown synthetic fixture action');
    }
  }
  final wallet = f.success(await store.read((r) => r.wallet()));
  final achievements = f.success(await store.read((r) => r.achievements()));
  final active = f.success(await store.read((r) => r.activeSession()));
  stdout.writeln(
    jsonEncode({
      'fixturePid': pid,
      'status': session!.status.name,
      'settled': session.settled.value,
      'coins': wallet.balances.coins.units,
      'revision': session.revision.value,
      'deadline': session.deadlineUtc?.millisecondsSinceEpoch,
      'boot': session.checkpoint.bootId,
      'completionId': session.completionId.value,
      'achievements': achievements.length,
      'active': active != null,
    }),
  );
  await stdout.flush();
  // Keep the process alive until SIGKILL; no graceful close/finally can help.
  await Future<void>.delayed(const Duration(days: 1));
}
