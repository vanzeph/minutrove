import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support.dart' as f;

const coins = VirtualCurrencyDimension(VirtualCurrency.coins);
const gems = VirtualCurrencyDimension(VirtualCurrency.gems);
final usd = BudgetCurrency.fromMetadata('USD', f.metadata);
CommandRequest request({
  int amount = 50,
  OperationKind kind = OperationKind.reconcileSession,
}) => CommandRequest(kind: kind, arguments: {'amount': amount, 'revision': 1});

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late String path;
  late SqliteStore store;
  late CommandCoordinator commands;
  Future<void> open({DatabaseFactory? factory}) async {
    store = f.success(
      await SqliteStore.open(
        path: path,
        factory: factory ?? databaseFactoryFfi,
        currencies: f.metadata,
        initialSettings: f.settings,
      ),
    );
    commands = CommandCoordinator(store);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('minutrove-command-');
    path = '${directory.path}/commands.db';
    await open();
    f.success(
      await store.write((tx) async {
        await tx.putItem(
          ItemRevision(snapshot: f.quest(), recordedAt: f.event),
        );
        await tx.putItem(
          ItemRevision(snapshot: f.award(), recordedAt: f.event),
        );
      }),
    );
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  Future<Result<EconomicState>> post(
    List<LedgerEntry> entries, {
    int op = 10,
    CommandRequest? arguments,
    Future<void> Function(CommandTransaction)? before,
  }) => commands.execute(
    operationId: OperationId(f.uuid(op)),
    request: arguments ?? request(),
    committedAt: (_) => f.event,
    action: (tx) async {
      await before?.call(tx);
      await tx.postLedger(entries);
      return tx.economicState();
    },
  );
  LedgerEntry credit(int amount, {int op = 10, int n = 20}) =>
      f.entry(f.quest(), coins, amount, op: op, n: n);
  Future<void> audit() async => expect(
    f.success(await store.read((r) => r.projectionMismatches())),
    isEmpty,
  );

  test(
    'canonical request freezes nested values and distinguishes exact inputs',
    () {
      final nested = <String, Object?>{
        'b': 2,
        'a': [true, null, '3'],
      };
      final original = CommandRequest(
        kind: OperationKind.redeemAward,
        arguments: {'x': nested},
      );
      final same = CommandRequest(
        kind: OperationKind.redeemAward,
        arguments: {
          'x': {
            'a': [true, null, '3'],
            'b': 2,
          },
        },
      );
      expect(original.fingerprint, same.fingerprint);
      expect(original.fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
      nested['b'] = 3;
      expect(original.fingerprint, same.fingerprint);
      expect(
        CommandRequest(
          kind: OperationKind.redeemAward,
          arguments: {'x': nested},
        ).fingerprint,
        isNot(original.fingerprint),
      );
      expect(
        () =>
            CommandRequest(kind: OperationKind.saveItem, arguments: {'x': 1.0}),
        throwsA(isA<InvalidInput>()),
      );
      expect(
        () => CommandRequest(
          kind: OperationKind.saveItem,
          arguments: {'x': Object()},
        ),
        throwsA(isA<InvalidInput>()),
      );
      expect(
        request(kind: OperationKind.recordExpense).fingerprint,
        isNot(request().fingerprint),
      );
    },
  );

  test(
    'concurrent duplicate commands execute and read the clock exactly once',
    () async {
      var actions = 0;
      var clocks = 0;
      final results = await Future.wait(
        List.generate(
          24,
          (_) => commands.execute(
            operationId: OperationId(f.uuid(10)),
            request: request(),
            committedAt: (_) {
              clocks++;
              return f.event;
            },
            action: (tx) async {
              actions++;
              await tx.requireItem(f.quest().id, Revision(1));
              await tx.postLedger([credit(50)]);
              return tx.economicState();
            },
          ),
        ),
      );
      expect(actions, 1);
      expect(clocks, 1);
      expect(
        results.map((r) => f.success(r).wallet.balances.coins.units),
        everyElement(50),
      );
      expect(f.success(await store.read((r) => r.ledger())).length, 1);
      await audit();
    },
  );

  test(
    'reopen and later edits replay original state before stale revision checks',
    () async {
      final original = f.success(await post([credit(50)]));
      f.success(await post([credit(10, op: 11, n: 21)], op: 11));
      f.success(
        await store.write(
          (r) => r.putItem(
            ItemRevision(snapshot: f.quest(revision: 2), recordedAt: f.event),
          ),
        ),
      );
      await store.close();
      await open();
      final replay = f.success(
        await post(
          [credit(50)],
          before: (tx) async {
            await tx.requireItem(f.quest().id, Revision(1));
            fail('Replay must not execute the callback');
          },
        ),
      );
      const codec = RecordCodec(f.metadata);
      expect(codec.encode(replay), codec.encode(original));
      expect(
        f.success(await store.read((r) => r.wallet())).balances.coins.units,
        60,
      );
      await audit();
    },
  );

  test(
    'conflicting arguments, kind and result type reject without effects',
    () async {
      f.success(await post([credit(50)]));
      for (final args in [
        request(amount: 51),
        request(kind: OperationKind.recordExpense),
      ]) {
        expect(
          await post([credit(51)], arguments: args),
          isA<Failure<EconomicState>>().having(
            (v) => v.error,
            'error',
            isA<InvalidInput>(),
          ),
        );
      }
      expect(
        await commands.execute<bool>(
          operationId: OperationId(f.uuid(10)),
          request: request(),
          committedAt: (_) => throw StateError('Must not read the clock'),
          action: (_) async => throw StateError('Must not execute'),
        ),
        isA<Failure<bool>>().having(
          (v) => v.error,
          'error',
          isA<InvalidInput>(),
        ),
      );
      expect(f.success(await store.read((r) => r.ledger())).length, 1);
    },
  );

  test(
    'joint debit and independent pooled dimensions derive from one ledger',
    () async {
      f.success(
        await post([
          credit(100),
          f.entry(f.quest(), gems, 20, op: 10, n: 21),
          f.entry(f.award(), const TimeDimension(), 2700000, op: 10, n: 22),
          f.entry(f.award(), BudgetDimension(usd), 3500, op: 10, n: 23),
        ]),
      );
      final state = f.success(
        await post(
          [
            f.entry(f.award(), coins, -60, op: 11, n: 24),
            f.entry(f.award(), gems, -6, op: 11, n: 25),
            f.entry(f.award(), const TimeDimension(), 1800000, op: 11, n: 26),
            f.entry(f.award(), BudgetDimension(usd), -1250, op: 11, n: 27),
          ],
          op: 11,
          before: (tx) async {
            await tx.requireItem(f.award().id, Revision(1));
            await tx.requireAward(f.award().id, Revision(1));
            await tx.requireWallet(Revision(2));
          },
        ),
      );
      expect(state.wallet.balances.coins.units, 40);
      expect(state.wallet.balances.gems.units, 14);
      expect(state.wallet.revision.value, 3);
      expect(state.awards.single.time!.value, 4500000);
      expect(state.awards.single.budget!.minorUnits, 2250);
      expect(state.awards.single.revision.value, 2);
      expect(state.entries.length, 4);
      final used = f.success(
        await post([
          f.entry(f.award(), const TimeDimension(), -4500000, op: 12, n: 28),
        ], op: 12),
      );
      expect(used.awards.single.isExhausted, isFalse);
      expect(used.awards.single.budget!.minorUnits, 2250);
      await audit();
    },
  );

  test('insufficient both currencies and exceeded allowances roll back related writes', () async {
    final result = await post([
      credit(-1),
      f.entry(f.quest(), gems, -2, op: 10, n: 21),
    ], before: (tx) => tx.records.putGroup(f.group()));
    final error = (result as Failure).error as InsufficientFunds;
    expect(error.coins, isTrue);
    expect(error.gems, isTrue);
    expect(f.success(await store.read((r) => r.groups())), isEmpty);
    expect(
      await post([f.entry(f.award(), const TimeDimension(), -1, op: 10)]),
      isA<Failure<EconomicState>>().having(
        (v) => v.error,
        'error',
        isA<AllowanceExceeded>(),
      ),
    );
    expect(
      f.success(
        await store.read((r) => r.operation<Object>(OperationId(f.uuid(10)))),
      ),
      isNull,
    );
    // A rejected operation did not consume its ID and may be retried.
    f.success(await post([credit(50)]));
    await audit();
  });

  test(
    'BigInt totals do not wrap and overflow never partially debits a wallet',
    () async {
      final state = f.success(
        await post([
          credit(maxStoredInteger),
          credit(maxStoredInteger, n: 21),
          credit(-maxStoredInteger, n: 22),
        ]),
      );
      expect(state.wallet.balances.coins.units, maxStoredInteger);
      expect(
        await post([credit(1, op: 11, n: 23)], op: 11),
        isA<Failure<EconomicState>>().having(
          (v) => v.error,
          'error',
          isA<NumericOverflow>(),
        ),
      );
      f.success(
        await post([
          f.entry(
            f.award(),
            const TimeDimension(),
            maxStoredInteger,
            op: 12,
            n: 24,
          ),
        ], op: 12),
      );
      expect(
        await post([
          credit(-1, op: 13, n: 25),
          f.entry(f.award(), const TimeDimension(), 1, op: 13, n: 26),
        ], op: 13),
        isA<Failure<EconomicState>>().having(
          (v) => v.error,
          'error',
          isA<NumericOverflow>(),
        ),
      );
      expect(
        f.success(await store.read((r) => r.wallet())).balances.coins.units,
        maxStoredInteger,
      );
      await audit();
    },
  );

  test(
    'revision guards serialize competing writes and check absent balances',
    () async {
      final results = await Future.wait(
        List.generate(
          2,
          (i) => post(
            [credit(1, op: 10 + i, n: 20 + i)],
            op: 10 + i,
            before: (tx) async {
              await tx.requireWallet(Revision(1));
            },
          ),
        ),
      );
      expect(results.whereType<Success<EconomicState>>().length, 1);
      expect(
        (results.whereType<Failure<EconomicState>>().single).error,
        isA<StaleRevision>(),
      );
      for (final before in <Future<void> Function(CommandTransaction)>[
        (tx) async {
          await tx.requireItem(f.quest().id, Revision(2));
        },
        (tx) async {
          await tx.requireItem(ItemId(f.uuid(99)), Revision(1));
        },
        (tx) async {
          await tx.requireAward(f.award().id, Revision(1));
        },
        (tx) async {
          await tx.requireSession(SessionId(f.uuid(99)), Revision(1));
        },
      ]) {
        expect(
          await post([], op: 30, before: before),
          isA<Failure<EconomicState>>(),
        );
      }
      f.success(
        await post(
          [],
          op: 31,
          before: (tx) async {
            expect(await tx.requireAward(f.award().id, null), isNull);
          },
        ),
      );
      await audit();
    },
  );

  test('session snapshot, operation and dimension mismatches reject atomically', () async {
    f.success(await store.write((r) => r.putSession(f.session(f.quest()))));
    for (final entries in [
      [credit(1, op: 99)],
      [credit(1), credit(2)],
      [f.entry(f.quest(), const TimeDimension(), -1, op: 10)],
      [f.entry(f.quest(), BudgetDimension(usd), 1, op: 10)],
      [
        f.entry(
          f.award(),
          BudgetDimension(BudgetCurrency.fromMetadata('JPY', f.metadata)),
          1,
          op: 10,
        ),
      ],
      [f.entry(f.award(), coins, 1, op: 10, sessionId: SessionId(f.uuid(4)))],
    ]) {
      expect(
        await post(entries),
        isA<Failure<EconomicState>>().having(
          (v) => v.error,
          'error',
          isA<InvalidInput>(),
        ),
      );
    }
    f.success(
      await store.write(
        (r) => r.putItem(
          ItemRevision(snapshot: f.quest(revision: 2), recordedAt: f.event),
        ),
      ),
    );
    // Old session snapshot remains a valid ledger attribution after item edit.
    f.success(
      await post([
        f.entry(f.quest(), coins, 1, op: 10, sessionId: SessionId(f.uuid(4))),
      ]),
    );
    await audit();
  });

  test(
    'stale result or manual projection drift rolls back all command effects',
    () async {
      expect(
        await commands.execute(
          operationId: OperationId(f.uuid(10)),
          request: request(),
          committedAt: (_) => f.event,
          action: (tx) async {
            final stale = await tx.economicState();
            await tx.postLedger([credit(50)]);
            return stale;
          },
        ),
        isA<Failure<EconomicState>>().having(
          (v) => v.error,
          'error',
          isA<InvalidInput>(),
        ),
      );
      expect(
        await commands.execute(
          operationId: OperationId(f.uuid(10)),
          request: request(),
          committedAt: (_) => f.event,
          action: (tx) async {
            await tx.records.putWallet(
              WalletProjection(revision: Revision(2), balances: f.amounts(1)),
            );
            return true;
          },
        ),
        isA<Failure<bool>>().having(
          (v) => v.error,
          'error',
          isA<StorageUnavailable>(),
        ),
      );
      expect(f.success(await store.read((r) => r.ledger())), isEmpty);
      expect(
        f.success(
          await store.read((r) => r.operation<Object>(OperationId(f.uuid(10)))),
        ),
        isNull,
      );
      await audit();
    },
  );

  test('failure at every SQL write and either side of COMMIT retains all or nothing', () async {
    await store.close();
    final factory = FaultFactory();
    await open(factory: factory);
    f.success(
      await post([
        credit(100, op: 90, n: 90),
        f.entry(f.quest(), gems, 20, op: 90, n: 91),
        f.entry(f.award(), const TimeDimension(), 60000, op: 90, n: 92),
        f.entry(f.award(), BudgetDimension(usd), 1000, op: 90, n: 93),
      ], op: 90),
    );
    f.success(
      await store.write((tx) async {
        await tx.putSession(f.session(f.quest()));
        await tx.insertGoal(
          DailyGoalRevision(
            questId: f.quest().id,
            revision: Revision(1),
            effectiveFrom: f.event.day,
            zone: f.zone,
            goal: (f.quest().configuration as QuestConfiguration).dailyGoal,
          ),
        );
      }),
    );
    await store.close();
    final baseline = await File(path).readAsBytes();
    await open(factory: factory);

    Future<Result<SessionMutation>> settle() => commands.execute(
      operationId: OperationId(f.uuid(10)),
      request: request(),
      committedAt: (_) => f.event,
      action: (tx) async {
        await tx.requireSession(SessionId(f.uuid(4)), Revision(1));
        await tx.records.putGroup(f.group());
        final session = f.session(
          f.quest(),
          status: SessionStatus.paused,
          revision: 2,
        );
        await tx.records.putSession(session);
        await tx.records.putRemainder(
          QuestAccrualRemainder(
            questId: f.quest().id,
            currency: VirtualCurrency.coins,
            remainder: AccrualRemainder(123),
          ),
        );
        await tx.records.putRemainder(
          QuestAccrualRemainder(
            questId: f.quest().id,
            currency: VirtualCurrency.gems,
            remainder: AccrualRemainder(456),
          ),
        );
        await tx.records.insertAchievement(
          DailyAchievement(
            questId: f.quest().id,
            day: f.event.day,
            goalRevision: Revision(1),
            operationId: tx.operationId,
            awardedAt: f.event,
            bonus: f.amounts(10),
          ),
        );
        await tx.postLedger([
          credit(50),
          f.entry(f.award(), coins, -20, op: 10, n: 25),
          f.entry(f.award(), gems, -1, op: 10, n: 26),
          f.entry(f.quest(), gems, 2, op: 10, n: 21),
          f.entry(
            f.quest(),
            const TimeDimension(),
            10000,
            op: 10,
            n: 22,
            sessionId: session.id,
          ),
          f.entry(f.award(), const TimeDimension(), 60000, op: 10, n: 23),
          f.entry(f.award(), BudgetDimension(usd), -100, op: 10, n: 24),
        ]);
        final intent = NotificationIntent(
          sessionId: session.id,
          sessionRevision: session.revision,
          completionId: session.completionId,
          deadlineUtc: null,
          completionChimeHandled: false,
        );
        await tx.records.putNotificationIntent(intent);
        return SessionMutation(
          session: session,
          economy: await tx.economicState(),
          notificationIntent: intent,
        );
      },
    );

    factory.arm();
    final committed = f.success(await settle());
    final writes = factory.writes;
    expect(writes, greaterThan(15));
    // Keep the actual matrix size visible in the acceptance log.
    // ignore: avoid_print
    print('Acceptance matrix: $writes SQL writes and both COMMIT boundaries');
    factory.disarm();
    await store.close();
    final full = await dump(path);
    const codec = RecordCodec(f.metadata);
    for (final failure in [...List.generate(writes, (i) => i + 1), -1, -2]) {
      await File(path).writeAsBytes(baseline, flush: true);
      await open(factory: factory);
      factory.arm(failure: failure);
      final rejected = await settle();
      expect(
        rejected,
        isA<Failure<SessionMutation>>(),
        reason: 'boundary $failure',
      );
      factory.disarm();
      await store.close();
      if (failure == -2) {
        // COMMIT succeeded but its acknowledgement was lost.
        expect(await dump(path), full);
      } else {
        expect(
          await File(path).readAsBytes(),
          baseline,
          reason: 'boundary $failure',
        );
      }
      await open(factory: factory);
      final retry = f.success(await settle());
      expect(codec.encode(retry), codec.encode(committed));
      await audit();
      await store.close();
      expect(await dump(path), full, reason: 'retry boundary $failure');
    }
    await open();
  });
}

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
/// after a write, before COMMIT (-1), or after a durable COMMIT (-2).
class FaultFactory implements DatabaseFactory {
  bool armed = false;
  int writes = 0;
  int? failure;
  void arm({int? failure}) {
    armed = true;
    writes = 0;
    this.failure = failure;
  }

  void disarm() {
    armed = false;
  }

  void hit() {
    if (armed && ++writes == failure) {
      throw const StorageUnavailable(retryable: true);
    }
  }

  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async => FaultDatabase(
    await databaseFactoryFfi.openDatabase(path, options: options),
    this,
  );
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
