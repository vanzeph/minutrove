import 'dart:async';
import 'dart:io';

import 'package:sqflite_common/sqlite_api.dart';

import '../domain/domain.dart';
import 'record_codec.dart';
import 'schema.dart';
import 'store_records.dart';

/// Own one store per live file. Native sqflite performs I/O off the UI thread.
/// All record operations share its queue and transaction boundary.
final class SqliteStore {
  SqliteStore._(this._db, this._codec);
  final Database _db;
  final RecordCodec _codec;
  final _changes = StreamController<void>.broadcast();
  Future<void> _tail = Future.value();
  bool _closed = false;

  /// `initialSettings` is used only for a genuinely empty database. An unknown,
  /// newer, malformed or failed schema is never replaced with an empty one.
  static Future<Result<SqliteStore>> open({
    required String path,
    required DatabaseFactory factory,
    required CurrencyMetadata currencies,
    required AppSettings initialSettings,
    List<SchemaMigration>? migrations,
  }) async {
    Database? db;
    try {
      final plan = List<SchemaMigration>.of(migrations ?? schemaMigrations);
      if (plan.isEmpty || plan.indexed.any((e) => e.$2.version != e.$1 + 1)) {
        throw const InvalidInput(
          'migrations',
          'Expected contiguous versions starting at one',
        );
      }
      db = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (database) async {
            await database.execute('PRAGMA foreign_keys = ON');
            await database.execute('PRAGMA busy_timeout = 5000');
            await database.execute('PRAGMA synchronous = FULL');
          },
        ),
      );
      final codec = RecordCodec(currencies);
      await _runTransaction(db, (tx) async {
        final current =
            (await tx.rawQuery('PRAGMA user_version')).single.values.single
                as int;
        if (current > plan.last.version || current < 0) {
          throw const FormatException('Unsupported database schema');
        }
        if (current == 0) {
          final existing = await tx.rawQuery(
            "SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND name != 'android_metadata'",
          );
          if (existing.isNotEmpty) {
            throw const FormatException('Unversioned nonempty database');
          }
        } else {
          await _validateDatabase(tx, current);
        }
        for (final migration in plan.skip(current)) {
          await migration.apply(tx);
          await tx.rawUpdate(
            'INSERT OR REPLACE INTO schema_version(singleton, version) VALUES (1, ?)',
            [migration.version],
          );
          await tx.execute('PRAGMA user_version = ${migration.version}');
        }
        if (current == 0) {
          await StoreTransaction(tx, codec).putSettings(initialSettings);
        }
        await _validateDatabase(tx, plan.last.version);
        if ((await StoreReader(tx, codec).projectionMismatches()).isNotEmpty) {
          throw const FormatException('Ledger and projections disagree');
        }
      }, exclusive: true);
      return Success(SqliteStore._(db, codec));
    } catch (error) {
      if (db != null) {
        try {
          await db.close();
        } catch (_) {
          /* Retain original and journal. */
        }
      }
      return Failure(_storageError(error));
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  /// Consistent read snapshot, serialized with mutations and close.
  Future<Result<T>> read<T>(Future<T> Function(StoreReader reader) action) =>
      _serialize(() async {
        if (_closed) return const Failure(StorageUnavailable(retryable: false));
        try {
          return Success(
            await _runTransaction(
              _db,
              (tx) => action(StoreReader(tx, _codec)),
              exclusive: false,
            ),
          );
        } catch (error) {
          return Failure(_storageError(error));
        }
      });

  /// Throw a DomainError to reject a command. A returned Failure also rolls back.
  /// Only after COMMIT succeeds are values or change notifications observable.
  /// Revision, duplicate replay and business checks belong to command adapters.
  Future<Result<T>> write<T>(Future<T> Function(StoreTransaction tx) action) =>
      _serialize(() async {
        if (_closed) return const Failure(StorageUnavailable(retryable: false));
        try {
          final value = await _runTransaction(_db, (tx) async {
            final records = StoreTransaction(tx, _codec);
            final result = await action(records);
            if (result is Failure) throw result.error;
            if ((await records.projectionMismatches()).isNotEmpty) {
              throw const FormatException('Ledger and projections disagree');
            }
            // Report deferred relationship failures before COMMIT so adapters
            // can issue ROLLBACK with a live transaction handle on every OS.
            if ((await tx.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
              throw const FormatException('Missing referenced record');
            }
            return result;
          }, exclusive: true);
          _changes.add(null);
          return Success(value);
        } on DomainError catch (error) {
          return Failure(error);
        } catch (error) {
          return Failure(_storageError(error));
        }
      });

  /// Each subscriber gets a current committed snapshot and future commits.
  /// Errors are typed stream errors; a later successful read can recover.
  Stream<T> watch<T>(Future<T> Function(StoreReader reader) query) {
    late StreamController<T> controller;
    StreamSubscription<void>? subscription;
    Future<void> pending = Future.value();
    void refresh() {
      pending = pending.then((_) async {
        final result = await read(query);
        if (controller.isClosed) return;
        switch (result) {
          case Success<T>(:final value):
            controller.add(value);
          case Failure<T>(:final error):
            controller.addError(error);
        }
      });
    }

    controller = StreamController<T>(
      onListen: () {
        subscription = _changes.stream.listen(
          (_) => refresh(),
          onDone: () async {
            await pending;
            await controller.close();
          },
        );
        refresh();
      },
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  Future<void> close() => _serialize(() async {
    if (_closed) return;
    _closed = true;
    await _db.close();
    // Do not await listeners, which may have paused or queued a final read.
    unawaited(_changes.close());
  });
}

Future<T> _runTransaction<T>(
  Database db,
  Future<T> Function(Transaction) action, {
  required bool exclusive,
}) async {
  var bodyCompleted = false;
  try {
    return await db.transaction((tx) async {
      final value = await action(tx);
      bodyCompleted = true;
      return value;
    }, exclusive: exclusive);
  } catch (_) {
    if (bodyCompleted) {
      // sqflite closes its Dart transaction handle even when SQLite COMMIT
      // fails. Close the uncertain connection: SQLite rolls back any remaining
      // transaction. Never issue another command on that connection. Reopening
      // the same file recovers the journal without resetting the user's data.
      await db.close();
      throw const StorageUnavailable(retryable: true);
    }
    rethrow;
  }
}

Future<void> _validateDatabase(DatabaseExecutor db, int version) async {
  final integrity = await db.rawQuery('PRAGMA integrity_check');
  if (integrity.length != 1 ||
      integrity.single.values.single != 'ok' ||
      (await db.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
    throw const FormatException('Database integrity check failed');
  }
  final row = await db.query('schema_version');
  if (row.length != 1 ||
      row.single['singleton'] != 1 ||
      row.single['version'] != version) {
    throw const FormatException('Schema version records disagree');
  }
  // Check the structural v1 baseline even when user_version claims to be current.
  for (final table in [
    'groups',
    'items',
    'item_revisions',
    'operations',
    'sessions',
    'active_intervals',
    'ledger_entries',
    'wallet_projection',
    'award_balances',
    'quest_accrual_remainders',
    'daily_goal_revisions',
    'daily_achievements',
    'app_settings',
    'notification_intents',
  ]) {
    await db.rawQuery('SELECT * FROM $table LIMIT 0');
  }
  if ((await db.query('wallet_projection')).length != 1 ||
      (await db.query('app_settings')).length != 1) {
    throw const FormatException('Missing singleton');
  }
}

DomainError _storageError(Object error) {
  if (error is StorageUnavailable) return error;
  // Invalid stored values must not be presented as invalid user input.
  if (error is DatabaseException) {
    final code = error.getResultCode();
    final primary = code == null ? null : code & 0xff;
    return StorageUnavailable(retryable: [5, 6, 10, 13, 14].contains(primary));
  }
  if (error is FileSystemException) {
    return const StorageUnavailable(retryable: true);
  }
  return const StorageUnavailable(retryable: false);
}
