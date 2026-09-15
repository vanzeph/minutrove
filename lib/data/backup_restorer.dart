import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../domain/domain.dart';
import 'backup_codec.dart';
import 'backup_converters.dart';
import 'backup_exporter.dart';
import 'backup_record_codec.dart';
import 'command_coordinator.dart';
import 'record_codec.dart';
import 'sqlite_store.dart';

/// Restore half of the BackupRepository port, plus the store lifecycle a file
/// replacement requires. The adapter owns the live database file: validation
/// materializes the decoded snapshot into a temporary store beside it, the
/// original is copied to a retained safety file and verified, and only then
/// does an atomic same-directory rename replace the live file. Any failure or
/// interruption before, during or after the swap leaves the original usable.
/// The database is re-opened before the restore is acknowledged, temporary
/// validation files are removed, and stale OS notifications are canceled
/// through the scheduler port with the (always empty) restored intents.
///
/// Restore replaces current data exactly as confirmed; it does not merge and
/// never restarts a timer. Imported snapshots contain no active session, so
/// the slot is empty afterwards and no bonus can be paid again. Historical
/// operation results are decoded as inert replay data only.
final class SqliteBackupRestorer {
  SqliteBackupRestorer._({
    required SqliteStore live,
    required this.databasePath,
    required this.factory,
    required this.currencies,
    required this.initialSettings,
    required this.clock,
    required this.calendar,
    required this.scheduler,
    required this.codec,
    required this.converters,
  }) : _store = live;

  static Future<Result<SqliteBackupRestorer>> open({
    required String path,
    required DatabaseFactory factory,
    required CurrencyMetadata currencies,
    required AppSettings initialSettings,
    required Clock clock,
    required ReportingCalendar calendar,
    NotificationScheduler? scheduler,
    BackupCodec codec = const BackupCodec(),
    List<BackupConverter>? converters,
  }) async {
    final opened = await SqliteStore.open(
      path: path,
      factory: factory,
      currencies: currencies,
      initialSettings: initialSettings,
    );
    return switch (opened) {
      Success(:final value) => Success(
        SqliteBackupRestorer._(
          live: value,
          databasePath: path,
          factory: factory,
          currencies: currencies,
          initialSettings: initialSettings,
          clock: clock,
          calendar: calendar,
          scheduler: scheduler,
          codec: codec,
          converters: converters,
        ),
      ),
      Failure(:final error) => Failure(error),
    };
  }

  final String databasePath;
  final DatabaseFactory factory;
  final CurrencyMetadata currencies;
  final AppSettings initialSettings;
  final Clock clock;
  final ReportingCalendar calendar;
  final NotificationScheduler? scheduler;
  final BackupCodec codec;
  final List<BackupConverter>? converters;

  SqliteStore _store;
  Future<void> _tail = Future.value();
  bool _closed = false;

  /// Current live store; replaced by the reopened database after a restore.
  /// Rebuild repository adapters from this getter after a successful restore.
  SqliteStore get store => _store;

  String get _temporaryPath => '$databasePath.restore-tmp';
  String get _safetyPath => '$databasePath.restore-safety';

  Future<void> close() => _serialize(() async {
    if (_closed) return;
    _closed = true;
    await _store.close();
  });

  /// Full validation in a temporary database. Returns the preview the
  /// confirmation flow binds to; never touches live data or files.
  Future<Result<BackupPreview>> inspectBackup(BackupFile file) => _serialize(
    () => _guard(() async {
      final decoded = _decodeSnapshot(file);
      await _validateInTemporaryStore(decoded);
      return decoded.preview;
    }),
  );

  /// Requires explicit in-app replacement confirmation bound to the whole-file
  /// digest and the settings revision the user confirmed against. Revalidates
  /// everything into a fresh temporary store (including the durable restore
  /// operation row), then swaps atomically and reopens.
  Future<Result<RestoreReceipt>> restoreBackup({
    required OperationId operationId,
    required BackupFile file,
    required RestoreConfirmation confirmation,
  }) => _serialize(
    () => _guard(() async {
      if (_closed) throw const StorageUnavailable(retryable: false);
      final request = CommandRequest(
        kind: OperationKind.restoreBackup,
        arguments: {
          'sha256': sha256.convert(file.bytes).toString(),
          'expectedSettingsRevision':
              confirmation.expectedSettingsRevision.value,
        },
      );
      final read = await _store.read(
        (records) async => (
          await records.operation<Object>(operationId),
          await records.settings(),
        ),
      );
      final (prior, liveSettings) = switch (read) {
        Success(:final value) => value,
        Failure(:final error) => throw error,
      };
      if (prior != null) {
        if (prior.kind != OperationKind.restoreBackup ||
            prior.requestFingerprint != request.fingerprint ||
            prior.committedResult is! RestoreReceipt) {
          throw const InvalidInput(
            'operationId',
            'Conflicting operation reuse',
          );
        }
        return prior.committedResult as RestoreReceipt;
      }
      final decoded = _decodeSnapshot(file);
      if (decoded.preview.sha256 != confirmation.preview.sha256 ||
          decoded.preview.createdUtc != confirmation.preview.createdUtc ||
          decoded.preview.version.value != confirmation.preview.version.value ||
          !_sameRecordCounts(
            decoded.preview.recordCounts,
            confirmation.preview,
          )) {
        throw const InvalidInput(
          'confirmation',
          'Backup differs from inspection',
        );
      }
      if (liveSettings.revision != confirmation.expectedSettingsRevision) {
        throw const StaleRevision();
      }
      final zone = decoded.settings.reportingZone;
      if (!calendar.supports(zone)) {
        throw const InvalidBackup('Unsupported reporting zone');
      }
      final receipt = RestoreReceipt(
        operationId: operationId,
        sourceSha256: decoded.preview.sha256,
        schemaVersion: SchemaVersion(currentBackupSchemaVersion),
        settings: decoded.settings,
      );
      await _validateInTemporaryStore(
        decoded,
        restore: Operation<RestoreReceipt>(
          id: operationId,
          kind: OperationKind.restoreBackup,
          committedAt: await _clockEvent(zone),
          requestFingerprint: request.fingerprint,
          committedResult: receipt,
        ),
      );
      try {
        await _replaceAndReopen();
      } finally {
        // After a successful swap the temporary path no longer exists; after
        // a failed one nothing references the validated file anymore.
        await _deleteQuietly(_temporaryPath);
      }
      await _cancelStaleNotifications(operationId);
      return receipt;
    }),
  );

  _DecodedBackup _decodeSnapshot(BackupFile file) {
    try {
      final decoded = codec.decode(file);
      if (decoded.snapshot.currencyMetadataVersion != currencies.version) {
        throw const InvalidBackup('Currency metadata differs');
      }
      final snapshot = upgradeBackupSnapshot(
        decoded.snapshot,
        chain: converters,
      );
      final preview = BackupPreview(
        version: decoded.preview.version,
        createdUtc: snapshot.createdUtc,
        sha256: decoded.preview.sha256,
        recordCounts: snapshot.recordCounts,
      );
      return _validateDecoded(snapshot, preview);
    } on InvalidBackup {
      rethrow;
    } on UnsupportedBackupVersion {
      rethrow;
    } on StorageUnavailable {
      rethrow;
    } on DomainError {
      // Invalid ranges, identifiers or enum names in the file, not caller
      // input; never include file contents in the surfaced reason.
      throw const InvalidBackup('Record validation failed');
    } on FormatException {
      throw const InvalidBackup('Record validation failed');
    }
  }

  _DecodedBackup _validateDecoded(
    BackupSnapshot snapshot,
    BackupPreview preview,
  ) {
    final portable = const BackupRecordCodec();
    List<T> collection<T>(String name) =>
        (snapshot.records[name] ??
                (throw const InvalidBackup('Missing snapshot collection')))
            .map((record) => portable.fromJson(record, currencies) as T)
            .toList();
    final internal = RecordCodec(currencies);
    final decoded = _DecodedBackup(
      preview: preview,
      groups: collection('groups'),
      itemRevisions: collection('itemRevisions')
        ..sort((a, b) {
          final byItem = a.snapshot.id.value.compareTo(b.snapshot.id.value);
          return byItem != 0
              ? byItem
              : a.snapshot.revision.value.compareTo(b.snapshot.revision.value);
        }),
      currentItems: collection('items'),
      sessions: collection('sessions'),
      operations: collection('operations'),
      ledger: collection('ledger'),
      wallet: collection<WalletProjection>('wallet').single,
      awards: collection('awardBalances'),
      remainders: collection('accrualRemainders'),
      goals: collection('goalRevisions'),
      achievements: collection('achievements'),
      settings: collection<AppSettings>('settings').single,
    );

    Never rejected() => throw const InvalidBackup('Missing referenced record');
    Never duplicated() => throw const InvalidBackup('Duplicate record');
    void unique<K>(Iterable<K> keys) {
      if (keys.toSet().length != keys.length) duplicated();
    }

    unique(decoded.groups.map((g) => g.id));
    unique(decoded.currentItems.map((i) => i.id));
    unique(
      decoded.itemRevisions.map((r) => (r.snapshot.id, r.snapshot.revision)),
    );
    unique(decoded.sessions.map((s) => s.id));
    unique(decoded.operations.map((o) => o.id));
    unique(decoded.ledger.map((e) => e.id));
    unique(decoded.awards.map((a) => a.awardId));
    unique(decoded.remainders.map((r) => (r.questId, r.currency)));
    unique(decoded.goals.map((g) => (g.questId, g.revision)));
    unique(decoded.achievements.map((a) => (a.questId, a.day)));

    final groupIds = decoded.groups.map((g) => g.id).toSet();
    for (final item in decoded.currentItems) {
      if (item.groupId != null && !groupIds.contains(item.groupId)) rejected();
    }
    final revisions = <ItemId, List<ItemRevision>>{};
    for (final revision in decoded.itemRevisions) {
      revisions.putIfAbsent(revision.snapshot.id, () => []).add(revision);
    }
    for (final item in decoded.currentItems) {
      final history = revisions[item.id];
      // Every current pointer names an existing immutable revision, and the
      // append-only history means that revision is the item's latest one.
      if (history == null ||
          history.last.snapshot.revision != item.revision ||
          internal.encode(history.last.snapshot) != internal.encode(item)) {
        rejected();
      }
    }
    final operations = decoded.operations.map((o) => o.id).toSet();
    final sessions = decoded.sessions.map((s) => s.id).toSet();
    for (final session in decoded.sessions) {
      if (!revisions.containsKey(session.itemSnapshot.id) ||
          revisions[session.itemSnapshot.id]!.every(
            (r) => r.snapshot.revision != session.itemSnapshot.revision,
          )) {
        rejected();
      }
    }
    for (final entry in decoded.ledger) {
      if (!operations.contains(entry.operationId) ||
          !revisions.containsKey(entry.itemId) ||
          revisions[entry.itemId]!.every(
            (r) => r.snapshot.revision != entry.itemRevision,
          ) ||
          (entry.sessionId != null && !sessions.contains(entry.sessionId))) {
        rejected();
      }
    }
    final items = {for (final item in decoded.currentItems) item.id: item};
    final quests = items.values
        .where((i) => i.type == ItemType.quest)
        .map((i) => i.id)
        .toSet();
    for (final award in decoded.awards) {
      if (items[award.awardId]?.type != ItemType.award) rejected();
    }
    for (final remainder in decoded.remainders) {
      if (!quests.contains(remainder.questId)) rejected();
    }
    final goalKeys = {
      for (final goal in decoded.goals) (goal.questId, goal.revision),
    };
    for (final goal in decoded.goals) {
      if (!quests.contains(goal.questId)) rejected();
    }
    for (final achievement in decoded.achievements) {
      if (!goalKeys.contains((achievement.questId, achievement.goalRevision)) ||
          !operations.contains(achievement.operationId)) {
        rejected();
      }
    }
    return decoded;
  }

  /// Materializes the decoded snapshot inside a temporary database and checks
  /// uniqueness, relationships, schema constraints and ledger/projection
  /// agreement before anything can touch live data. The durable restore
  /// operation row is committed with the snapshot so replays of the same
  /// operation ID return the original receipt after the swap.
  Future<void> _validateInTemporaryStore(
    _DecodedBackup decoded, {
    Operation<RestoreReceipt>? restore,
  }) async {
    await _deleteFile(_temporaryPath);
    await _deleteFile('$_temporaryPath-journal');
    SqliteStore? temporary;
    try {
      final opened = await SqliteStore.open(
        path: _temporaryPath,
        factory: factory,
        currencies: currencies,
        initialSettings: decoded.settings,
      );
      temporary = switch (opened) {
        Success(:final value) => value,
        Failure(:final error) => throw error,
      };
      final result = await temporary.write((tx) async {
        // Sorted revisions leave the current pointer on each item's latest
        // history row, which validation proved equals the current snapshot.
        for (final group in decoded.groups) {
          await tx.putGroup(group);
        }
        for (final revision in decoded.itemRevisions) {
          await tx.putItem(revision);
        }
        for (final operation in decoded.operations) {
          await tx.insertOperation(operation);
        }
        for (final session in decoded.sessions) {
          await tx.putSession(session);
        }
        for (final entry in decoded.ledger) {
          await tx.insertLedger(entry);
        }
        await tx.putWallet(decoded.wallet);
        for (final award in decoded.awards) {
          await tx.putAward(award);
        }
        for (final remainder in decoded.remainders) {
          await tx.putRemainder(remainder);
        }
        for (final goal in decoded.goals) {
          await tx.insertGoal(goal);
        }
        for (final achievement in decoded.achievements) {
          await tx.insertAchievement(achievement);
        }
        await tx.putSettings(decoded.settings);
        if (restore != null) {
          await tx.insertOperation(restore);
        }
        if ((await tx.projectionMismatches()).isNotEmpty) {
          throw const InvalidBackup('Ledger and projections disagree');
        }
      });
      switch (result) {
        case Success():
          break;
        case Failure(:final error):
          throw error is StorageUnavailable || error is InvalidBackup
              ? error
              : const InvalidBackup('Restore validation failed');
      }
    } finally {
      await temporary?.close();
      if (restore == null) {
        // Validation-only must leave no files behind; a restore attempt
        // renames this path itself after its own confirmation checks.
        await _deleteFile(_temporaryPath);
        await _deleteFile('$_temporaryPath-journal');
      }
    }
  }

  /// Closes the live store, preserves and verifies a safety copy of the
  /// original, atomically renames the validated temporary database over the
  /// live path and reopens it. A failure before the rename leaves the original
  /// file untouched; a failure reopening the replaced file restores the safety
  /// copy before surfacing the error.
  Future<void> _replaceAndReopen() async {
    await _store.close();
    try {
      final safety = File(_safetyPath);
      if (await safety.exists()) {
        await safety.delete();
      }
      await File(databasePath).copy(_safetyPath);
      await _verifyUsableDatabase(_safetyPath);
      await File(_temporaryPath).rename(databasePath);
    } on Object {
      try {
        await _reopen();
      } catch (_) {
        // The untouched original file remains on disk for the next attempt.
      }
      rethrow;
    }
    try {
      await _reopen();
      // The renamed database owns the live path now; only its journal could
      // remain transiently and a clean close removed it.
      await _deleteQuietly('$_temporaryPath-journal');
    } on Object {
      try {
        await File(_safetyPath).copy(databasePath);
        await _reopen();
      } catch (_) {
        // The retained safety copy is the manual recovery path.
      }
      rethrow;
    }
  }

  Future<SqliteStore> _reopen() async {
    final opened = await SqliteStore.open(
      path: databasePath,
      factory: factory,
      currencies: currencies,
      initialSettings: initialSettings,
    );
    return switch (opened) {
      Success(:final value) => _store = value,
      Failure(:final error) => throw error,
    };
  }

  Future<void> _verifyUsableDatabase(String path) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final integrity = await db.rawQuery('PRAGMA integrity_check');
      final foreignKeys = await db.rawQuery('PRAGMA foreign_key_check');
      if (integrity.length != 1 ||
          integrity.single.values.single != 'ok' ||
          foreignKeys.isNotEmpty) {
        throw const StorageUnavailable(retryable: true);
      }
    } finally {
      await db.close();
    }
  }

  Future<EventTime> _clockEvent(ReportingZone zone) async {
    try {
      return calendar.assign((await clock.now()).utc, zone);
    } on DomainError {
      rethrow;
    } catch (_) {
      throw const StorageUnavailable(retryable: true);
    }
  }

  Future<void> _deleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      await _deleteFile(path);
    } catch (_) {
      // Cleanup is best effort; the next attempt removes stale files first.
    }
  }

  /// The restored database persists no notification intents, so reconciliation
  /// with an empty intent list cancels every stale OS request. Failure here
  /// cannot roll back the committed replacement; the empty persisted intents
  /// make the next lifecycle reconciliation retry the cancellation.
  Future<void> _cancelStaleNotifications(OperationId restore) async {
    final target = scheduler;
    if (target == null) return;
    try {
      await target.reconcile(
        operationId: _notificationReconcileId(restore),
        intents: const [],
      );
    } catch (_) {
      // See above: retried by the ordinary lifecycle reconciliation.
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<Result<T>> _guard<T>(Future<T> Function() action) async {
    try {
      return Success(await action());
    } on DomainError catch (error) {
      return Failure(error);
    } catch (error) {
      return Failure(_storageError(error));
    }
  }
}

/// Composes export and restore onto one BackupRepository view. Export always
/// targets the restorer's current live store, so a restored database is used
/// by subsequent exports without rebuilding this object.
final class SqliteBackupRepository implements BackupRepository {
  SqliteBackupRepository({
    required this.restorer,
    required this.clock,
    this.codec = const BackupCodec(),
  });

  final SqliteBackupRestorer restorer;
  final Clock clock;
  final BackupCodec codec;

  @override
  Future<Result<BackupFile>> exportBackup({required OperationId operationId}) =>
      SqliteBackupExporter(
        store: restorer.store,
        clock: clock,
        codec: codec,
      ).exportBackup(operationId: operationId);

  @override
  Future<Result<BackupPreview>> inspectBackup(BackupFile file) =>
      restorer.inspectBackup(file);

  @override
  Future<Result<RestoreReceipt>> restoreBackup({
    required OperationId operationId,
    required BackupFile file,
    required RestoreConfirmation confirmation,
  }) => restorer.restoreBackup(
    operationId: operationId,
    file: file,
    confirmation: confirmation,
  );
}

final class _DecodedBackup {
  _DecodedBackup({
    required this.preview,
    required this.groups,
    required this.itemRevisions,
    required this.currentItems,
    required this.sessions,
    required this.operations,
    required this.ledger,
    required this.wallet,
    required this.awards,
    required this.remainders,
    required this.goals,
    required this.achievements,
    required this.settings,
  });

  final BackupPreview preview;
  final List<Group> groups;
  final List<ItemRevision> itemRevisions;
  final List<Item> currentItems;
  final List<Session> sessions;
  final List<Operation<Object>> operations;
  final List<LedgerEntry> ledger;
  final WalletProjection wallet;
  final List<AwardBalance> awards;
  final List<QuestAccrualRemainder> remainders;
  final List<DailyGoalRevision> goals;
  final List<DailyAchievement> achievements;
  final AppSettings settings;
}

bool _sameRecordCounts(Map<String, int> left, BackupPreview right) {
  final counts = right.recordCounts;
  return left.length == counts.length &&
      left.entries.every((entry) => counts[entry.key] == entry.value);
}

OperationId _notificationReconcileId(OperationId restore) {
  final hex = sha256
      .convert(utf8.encode('restore-notifications-v1:${restore.value}'))
      .toString();
  return OperationId(
    '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
    '4${hex.substring(13, 16)}-8${hex.substring(17, 20)}-${hex.substring(20, 32)}',
  );
}

DomainError _storageError(Object error) {
  if (error is StorageUnavailable) return error;
  if (error is FileSystemException) {
    return const StorageUnavailable(retryable: true);
  }
  if (error is DatabaseException) {
    final code = error.getResultCode();
    final primary = code == null ? null : code & 0xff;
    return StorageUnavailable(retryable: [5, 6, 10, 13, 14].contains(primary));
  }
  return const StorageUnavailable(retryable: false);
}
