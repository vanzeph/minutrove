import 'dart:convert';

import 'package:minutrove/domain/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> dump(String path) async {
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  try {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    );
    return jsonEncode({
      for (final table in tables)
        table['name'] as String: await db.query(
          table['name'] as String,
          orderBy: 'rowid',
        ),
    });
  } finally {
    await db.close();
  }
}

/// Real SQLite is used for every statement. Inject only the transport failure
/// after a write, before COMMIT (-1), or after a durable COMMIT (-2). A
/// one-shot [FaultFactory.arm]'s `openFailure` interrupts a chosen
/// openDatabase call, simulating an interrupted replacement recovery path.
class FaultFactory implements DatabaseFactory {
  bool armed = false;
  int writes = 0;
  int? failure;
  int opens = 0;
  int? openFailure;
  void arm({int? failure, int? openFailure}) {
    armed = true;
    writes = 0;
    opens = 0;
    this.failure = failure;
    this.openFailure = openFailure;
  }

  void disarm() {
    armed = false;
  }

  void hit() {
    if (!armed) return;
    ++writes;
    if (failure != null && writes == failure) {
      throw const StorageUnavailable(retryable: true);
    }
  }

  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async {
    if (armed && openFailure != null && ++opens == openFailure) {
      openFailure = null;
      throw const StorageUnavailable(retryable: true);
    }
    return FaultDatabase(
      await databaseFactoryFfi.openDatabase(path, options: options),
      this,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FaultDatabase implements Database {
  FaultDatabase(this.inner, this.fault);
  final Database inner;
  final FaultFactory fault;
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction) action, {
    bool? exclusive,
  }) async {
    final result = await inner.transaction((tx) async {
      final value = await action(FaultTransaction(tx, fault));
      if (fault.armed && fault.failure == -1) {
        throw const StorageUnavailable(retryable: true);
      }
      return value;
    }, exclusive: exclusive);
    if (fault.armed && fault.failure == -2) {
      throw const StorageUnavailable(retryable: true);
    }
    return result;
  }

  @override
  Future<void> close() => inner.close();

  /// Read-only statements (integrity/foreign-key verification) pass through.
  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => inner.rawQuery(sql, arguments);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FaultTransaction implements Transaction {
  FaultTransaction(this.inner, this.fault);
  final Transaction inner;
  final FaultFactory fault;
  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => inner.query(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
  );
  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => inner.rawQuery(sql, arguments);
  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    await inner.execute(sql, arguments);
    fault.hit();
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    final value = await inner.rawUpdate(sql, arguments);
    fault.hit();
    return value;
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final value = await inner.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    );
    fault.hit();
    return value;
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final value = await inner.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
      conflictAlgorithm: conflictAlgorithm,
    );
    fault.hit();
    return value;
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final value = await inner.delete(table, where: where, whereArgs: whereArgs);
    fault.hit();
    return value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
