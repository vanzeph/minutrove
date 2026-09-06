import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/data.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support.dart' as f;

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late String path;
  SqliteStore? store;
  Future<Result<SqliteStore>> open({
    List<SchemaMigration>? migrations,
    DatabaseFactory? factory,
  }) => SqliteStore.open(
    path: path,
    factory: factory ?? databaseFactoryFfi,
    currencies: f.metadata,
    initialSettings: f.settings,
    migrations: migrations,
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('minutrove-sqlite-');
    path = '${directory.path}/test.db';
    store = f.success(await open());
  });
  tearDown(() async {
    await store?.close();
    await directory.delete(recursive: true);
  });

  test(
    'fresh schema initializes zero wallet and explicit reporting zone',
    () async {
      final wallet = f.success(await store!.read((r) => r.wallet()));
      expect(wallet.balances.isZero, isTrue);
      expect(
        f
            .success(await store!.read((r) => r.settings()))
            .reportingZone
            .ianaName,
        'Etc/UTC',
      );
      expect(f.success(await store!.read((r) => r.items())), isEmpty);
      expect(
        f.success(await store!.read((r) => r.projectionMismatches())),
        isEmpty,
      );
    },
  );

  test(
    'every entity and immutable operation result survives close and reopen',
    () async {
      f.success(await store!.write(f.seed));
      await store!.close();
      store = f.success(await open());
      f.success(
        await store!.read((r) async {
          final q = (await r.item(ItemId(f.uuid(1))))!;
          expect(q.name, 'Synthetic Quest');
          expect(q.groupId, f.group().id);
          expect((await r.groups()).single.name, 'Synthetic Group');
          expect(
            (await r.itemRevision(q.id, Revision(1)))!.recordedAt.utc,
            f.now,
          );
          final s = (await r.activeSession())!;
          expect(s.itemSnapshot.id, q.id);
          expect(s.intervals.single.active.value, 10000);
          expect(s.checkpoint.bootId, 'fixture-boot');
          expect(s.completionId, CompletionId(f.uuid(104)));
          expect((await r.wallet()).balances.coins.units, 100);
          expect((await r.awards()).single.budget!.minorUnits, 1000);
          expect(
            (await r.remainder(q.id, VirtualCurrency.coins))!.remainder.value,
            1234,
          );
          expect((await r.goals(q.id)).single.goal!.bonus.coins.units, 10);
          expect((await r.achievements()).single.day, f.event.day);
          expect(
            (await r.notificationIntents()).single.deadlineUtc,
            s.deadlineUtc,
          );
          expect(
            (await r.ledger(from: f.event.day, through: f.event.day)).length,
            4,
          );
          final op = (await r.operation<EconomicState>(
            OperationId(f.uuid(5)),
          ))!;
          expect(op.committedResult.entries.length, 4);
          expect(op.committedResult.activeSession!.intervals.length, 1);
          expect(op.committedResult.wallet.balances.coins.units, 100);
          expect(await r.hasHistory(q.id), isTrue);
          return true;
        }),
      );
    },
  );

  test('snapshots survive current edits and group deletion', () async {
    f.success(await store!.write(f.seed));
    f.success(
      await store!.write((tx) async {
        await tx.putItem(
          ItemRevision(
            snapshot: f.quest(
              revision: 2,
              groupId: f.group().id,
              name: 'Renamed',
            ),
            recordedAt: f.event,
          ),
        );
        await tx.deleteGroup(f.group().id);
      }),
    );
    expect(
      f.success(await store!.read((r) => r.item(ItemId(f.uuid(1)))))!.groupId,
      isNull,
    );
    expect(
      f.success(await store!.read((r) => r.item(ItemId(f.uuid(1)))))!.name,
      'Renamed',
    );
    expect(
      f.success(await store!.read((r) => r.activeSession()))!.itemSnapshot.name,
      'Synthetic Quest',
    );
    expect(
      f
          .success(await store!.read((r) => r.activeSession()))!
          .itemSnapshot
          .groupId,
      f.group().id,
    );
  });

  test(
    'a thrown domain failure rolls back definitions and economics',
    () async {
      final result = await store!.write((tx) async {
        await f.seed(tx);
        throw const StaleRevision();
      });
      expect((result as Failure).error, isA<StaleRevision>());
      expect(f.success(await store!.read((r) => r.items())), isEmpty);
      expect(
        f.success(await store!.read((r) => r.wallet())).balances.isZero,
        isTrue,
      );
      await store!.close();
      store = f.success(await open());
      expect(f.success(await store!.read((r) => r.ledger())), isEmpty);
    },
  );

  test(
    'a returned Failure cannot commit a partially applied transaction',
    () async {
      expect(
        await store!.write((tx) async {
          await tx.putGroup(f.group());
          return const Failure<bool>(NotFound());
        }),
        isA<Failure<Object?>>(),
      );
      expect(f.success(await store!.read((r) => r.groups())), isEmpty);
    },
  );

  test(
    'deferred foreign key fails commit and rolls back original writes',
    () async {
      final q = f.quest();
      expect(
        await store!.write((tx) async {
          await tx.putItem(ItemRevision(snapshot: q, recordedAt: f.event));
          await tx.insertLedger(
            f.entry(
              q,
              const VirtualCurrencyDimension(VirtualCurrency.coins),
              10,
            ),
          );
          await tx.putWallet(
            WalletProjection(revision: Revision(2), balances: f.amounts(10)),
          );
          // Missing operation row is detected by SQLite COMMIT.
        }),
        isA<Failure<Object?>>(),
      );
      expect(f.success(await store!.read((r) => r.items())), isEmpty);
      expect(
        f.success(await store!.read((r) => r.wallet())).balances.isZero,
        isTrue,
      );
    },
  );

  test(
    'unique operations, daily achievements and paused slot reject duplicates',
    () async {
      f.success(await store!.write(f.seed));
      expect(
        await store!.write((tx) async {
          await tx.putGroup(f.group(n: 20));
          await tx.insertOperation(f.operation(true));
        }),
        isA<Failure<Object?>>(),
      );
      expect(f.success(await store!.read((r) => r.groups())).length, 1);
      final achievement = f
          .success(await store!.read((r) => r.achievements()))
          .single;
      expect(
        await store!.write((tx) => tx.insertAchievement(achievement)),
        isA<Failure<Object?>>(),
      );
      f.success(
        await store!.write(
          (tx) => tx.putSession(
            f.session(
              f.quest(groupId: f.group().id),
              status: SessionStatus.paused,
              revision: 2,
            ),
          ),
        ),
      );
      expect(
        await store!.write(
          (tx) =>
              tx.putSession(f.session(f.quest(groupId: f.group().id), n: 21)),
        ),
        isA<Failure<Object?>>(),
      );
      expect(
        f.success(await store!.read((r) => r.activeSession()))!.status,
        SessionStatus.paused,
      );
      expect(
        f.success(await store!.read((r) => r.session(SessionId(f.uuid(21))))),
        isNull,
      );
    },
  );

  test('projection drift fails the entire transaction', () async {
    f.success(await store!.write(f.seed));
    expect(
      await store!.write((tx) async {
        await tx.putGroup(f.group(n: 20));
        await tx.putWallet(
          WalletProjection(revision: Revision(3), balances: f.amounts(99, 2)),
        );
      }),
      isA<Failure<Object?>>(),
    );
    expect(
      f.success(await store!.read((r) => r.wallet())).balances.coins.units,
      100,
    );
    expect(f.success(await store!.read((r) => r.groups())).length, 1);
  });

  test('concurrent transactions serialize and observe prior commits', () async {
    final results = await Future.wait(
      List.generate(
        8,
        (_) => store!.write((tx) async {
          final prior = await tx.group(f.group().id);
          final next = f.group(revision: (prior?.revision.value ?? 0) + 1);
          await tx.putGroup(next);
          return next;
        }),
      ),
    );
    expect(results.map((r) => f.success(r).revision.value).toList(), [
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
    ]);
  });

  test(
    'watch emits only after commit and recovers after rejected writes',
    () async {
      final snapshots = <List<Group>>[];
      final ready = Completer<void>();
      final changed = Completer<void>();
      final sub = store!.watch((r) => r.groups()).listen((v) {
        snapshots.add(v);
        if (!ready.isCompleted) ready.complete();
        if (v.isNotEmpty && !changed.isCompleted) changed.complete();
      });
      await ready.future;
      await store!.write((tx) async {
        await tx.putGroup(f.group());
        throw const NotFound();
      });
      f.success(await store!.write((tx) => tx.putGroup(f.group(n: 20))));
      await changed.future;
      expect(snapshots.length, 2);
      expect(snapshots.last.single.id, f.group(n: 20).id);
      await sub.cancel();
    },
  );

  test(
    'successful schema upgrade persists explicit version and existing data',
    () async {
      f.success(await store!.write(f.seed));
      await store!.close();
      final plan = [
        ...schemaMigrations,
        SchemaMigration(
          schemaMigrations.last.version + 1,
          (tx) => tx.execute(
            'CREATE TABLE upgrade_marker (id INTEGER PRIMARY KEY)',
          ),
        ),
      ];
      store = f.success(await open(migrations: plan));
      expect(
        f.success(await store!.read((r) => r.wallet())).balances.coins.units,
        100,
      );
      await store!.close();
      store = f.success(await open(migrations: plan));
      expect(f.success(await store!.read((r) => r.ledger())).length, 4);
      await store!.close();
      expect(
        await open(),
        isA<Failure<Object?>>(),
      ); // No automatic downgrade/reset.
      store = f.success(await open(migrations: plan));
    },
  );

  test(
    'failed multi-step upgrade rolls back DDL, data, and user_version',
    () async {
      f.success(await store!.write(f.seed));
      await store!.close();
      final before = await File(path).readAsBytes();
      expect(
        await open(
          migrations: [
            ...schemaMigrations,
            SchemaMigration(schemaMigrations.last.version + 1, (tx) async {
              await tx.execute('CREATE TABLE should_rollback (id INTEGER)');
              await tx.rawUpdate('UPDATE groups SET name = ?', ['WRONG']);
            }),
            SchemaMigration(schemaMigrations.last.version + 2, (tx) async {
              await tx.execute('CREATE TABLE also_rollback (id INTEGER)');
              throw const FormatException('Corrupt migration fixture');
            }),
          ],
        ),
        isA<Failure<Object?>>(),
      );
      expect(await File(path).readAsBytes(), before);
      store = f.success(await open());
      expect(
        f.success(await store!.read((r) => r.groups())).single.name,
        'Synthetic Group',
      );
      expect(
        f.success(await store!.read((r) => r.wallet())).balances.coins.units,
        100,
      );
      final db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      expect(await db.getVersion(), schemaMigrations.last.version);
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE name LIKE '%rollback'",
        ),
        isEmpty,
      );
      await db.close();
    },
  );

  test('corrupt file and unversioned nonempty file are retained', () async {
    await store!.close();
    final corrupt = File('${directory.path}/corrupt.db');
    await corrupt.writeAsString('not a database');
    final result = await SqliteStore.open(
      path: corrupt.path,
      factory: databaseFactoryFfi,
      currencies: f.metadata,
      initialSettings: f.settings,
    );
    expect(result, isA<Failure<Object?>>());
    expect(await corrupt.readAsString(), 'not a database');
    final rawPath = '${directory.path}/unknown.db';
    final db = await databaseFactoryFfi.openDatabase(rawPath);
    await db.execute('CREATE TABLE user_data (value TEXT)');
    await db.rawInsert("INSERT INTO user_data VALUES ('retain me')");
    await db.close();
    expect(
      await SqliteStore.open(
        path: rawPath,
        factory: databaseFactoryFfi,
        currencies: f.metadata,
        initialSettings: f.settings,
      ),
      isA<Failure<Object?>>(),
    );
    final check = await databaseFactoryFfi.openDatabase(rawPath);
    expect((await check.query('user_data')).single['value'], 'retain me');
    await check.close();
  });

  test(
    'real SQLITE_FULL leaves previously committed database usable',
    () async {
      f.success(await store!.write(f.seed));
      await store!.close();
      store = f.success(await open(factory: LimitedFactory()));
      final result = await store!.write((tx) async {
        await tx.putGroup(f.group(n: 20));
        await tx.putGroup(f.group(n: 21, name: 'x' * 2000000));
      });
      expect(result, isA<Failure<Object?>>());
      expect((result as Failure).error, isA<StorageUnavailable>());
      expect(
        ((result as Failure).error as StorageUnavailable).retryable,
        isTrue,
      );
      expect(
        f.success(await store!.read((r) => r.groups())).single.name,
        'Synthetic Group',
      );
      await store!.close();
      store = f.success(await open());
      expect(
        f.success(await store!.read((r) => r.wallet())).balances.coins.units,
        100,
      );
    },
  );

  test('real SQLITE_FULL during upgrade retains current schema', () async {
    f.success(await store!.write(f.seed));
    await store!.close();
    expect(
      await open(
        factory: LimitedFactory(),
        migrations: [
          ...schemaMigrations,
          SchemaMigration(schemaMigrations.last.version + 1, (tx) async {
            await tx.execute('CREATE TABLE migration_blob (value BLOB)');
            await tx.rawInsert(
              'INSERT INTO migration_blob VALUES (zeroblob(2000000))',
            );
          }),
        ],
      ),
      isA<Failure<Object?>>(),
    );
    store = f.success(await open());
    expect(f.success(await store!.read((r) => r.ledger())).length, 4);
  });

  test(
    'frozen v1 migration fixture opens and preserves full records',
    () async {
      await store!.close();
      path = '${directory.path}/fixture.db';
      final raw = await databaseFactoryFfi.openDatabase(path);
      final sql = await File('test/data/fixtures/v1.sql').readAsString();
      await raw.transaction((tx) async {
        for (final statement in sql.split(';')) {
          if (statement.trim().isNotEmpty) await tx.execute(statement);
        }
      });
      await raw.close();
      store = f.success(await open());
      expect(f.success(await store!.read((r) => r.items())).length, 2);
      expect(
        f.success(await store!.read((r) => r.wallet())).balances.coins.units,
        100,
      );
      expect(
        f
            .success(await store!.read((r) => r.activeSession()))!
            .intervals
            .single
            .active
            .value,
        10000,
      );
      final before = f.success(
        await store!.read(
          (r) => r.operation<EconomicState>(OperationId(f.uuid(5))),
        ),
      )!;
      expect(before.committedResult.awards.single.budget!.minorUnits, 1000);
      await store!.close();
      store = f.success(
        await open(
          migrations: [
            ...schemaMigrations,
            SchemaMigration(
              schemaMigrations.last.version + 1,
              (tx) => tx.execute(
                'ALTER TABLE groups ADD COLUMN fixture_migrated INTEGER NOT NULL DEFAULT 1',
              ),
            ),
          ],
        ),
      );
      expect(
        f.success(await store!.read((r) => r.projectionMismatches())),
        isEmpty,
      );
    },
  );

  test(
    'COMMIT failure closes uncertain connection and reopening rolls back',
    () async {
      await store!.close();
      final factory = CommitFailureFactory();
      store = f.success(await open(factory: factory));
      factory.failCommit = true;
      expect(
        await store!.write((tx) => tx.putGroup(f.group())),
        isA<Failure<Object?>>(),
      );
      expect(await store!.read((r) => r.groups()), isA<Failure<Object?>>());
      store = f.success(await open());
      expect(f.success(await store!.read((r) => r.groups())), isEmpty);
      f.success(await store!.write((tx) => tx.putGroup(f.group(n: 20))));
      expect(
        f.success(await store!.read((r) => r.groups())).single.id,
        f.group(n: 20).id,
      );
    },
  );

  test(
    'read and write after close return typed unavailable failures',
    () async {
      await store!.close();
      expect(await store!.read((r) => r.wallet()), isA<Failure<Object?>>());
      expect(
        await store!.write((tx) => tx.putGroup(f.group())),
        isA<Failure<Object?>>(),
      );
    },
  );
}

/// Configure a real SQLite connection's capacity; no mocked write exceptions.
class LimitedFactory implements DatabaseFactory {
  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) =>
      databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) async {
            await options?.onConfigure?.call(db);
            final count =
                (await db.rawQuery('PRAGMA page_count')).single.values.single
                    as int;
            await db.rawQuery('PRAGMA max_page_count = ${count + 4}');
          },
        ),
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Inject a real deferred foreign-key violation after the callback has returned,
// forcing SQLite COMMIT (rather than a mocked statement) to fail.
class CommitFailureFactory implements DatabaseFactory {
  bool failCommit = false;
  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async => CommitFailureDatabase(
    await databaseFactoryFfi.openDatabase(path, options: options),
    this,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CommitFailureDatabase implements Database {
  CommitFailureDatabase(this.inner, this.factory);
  final Database inner;
  final CommitFailureFactory factory;
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction) action, {
    bool? exclusive,
  }) => inner.transaction((tx) async {
    final result = await action(tx);
    if (factory.failCommit) {
      factory.failCommit = false;
      await tx.rawInsert(
        'INSERT INTO items(id, revision, sort_order, archived) VALUES (?, 1, 0, 0)',
        [f.uuid(999)],
      );
    }
    return result;
  }, exclusive: exclusive);
  @override
  Future<void> close() => inner.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
