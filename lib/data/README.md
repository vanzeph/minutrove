# SQLite storage

`data.dart` exposes `SqliteStore`, transaction-scoped record adapters and the
versioned migration registry. `native_store.dart` supplies the Android/iOS
`sqflite` factory; tests supply `databaseFactoryFfi` against real SQLite files.
Native SQLite I/O runs on the plugin's background thread. Keep one store per live
file, inject pinned `CurrencyMetadata`, and supply the initial device reporting
zone through `AppSettings`. Initial settings apply only to a new, empty database.

```dart
final opened = await openNativeStore(
  path: privateDatabasePath,
  currencies: pinnedCurrencies,
  initialSettings: initialSettings,
);
switch (opened) {
  case Success<SqliteStore>(:final value):
    final wallet = await value.read((records) => records.wallet());
    // Compose commands with value.write((transaction) async { ... }).
  case Failure<SqliteStore>(:final error):
    // Show storage recovery/retry; never delete and recreate the database.
}
```

## Command integration

A `write` callback uses one `StoreTransaction` for all records. Callers read and
validate current state, append the new immutable item revisions, operations,
ledger and achievements, and write the corresponding session/projection/intent
records before returning the result. Throw a `DomainError` to reject the entire
command. Returning a `Failure` also rolls back. Await every storage method and
let failures propagate; do not swallow a failed write inside a transaction.

These are persistence primitives, not implementations of the product command
ports. The item and economic command adapters supply expected-revision checks,
history-safe edits, operation fingerprint comparison, duplicate result replay,
clock reconciliation, and goal calculations. Existing domain ports are unchanged.
Use `operation<T>(id)` and `insertOperation(Operation<T>)` to retrieve and persist
original results; unique operation IDs reject accidental duplicate inserts.
`RecordCodec` supports items, groups, item lists, economic/session results,
settings, restore receipts and booleans. Its tagged JSON is an internal v1 record
encoding, **not** the portable backup format. It checks saved budget precision
against the injected pinned metadata.

Mutations, consistent read snapshots, and close share one queue. Do not nest
store calls inside a callback, retain a reader/transaction after it returns, or
hold a transaction open for UI, network, or platform interaction. `watch(query)`
emits an initial snapshot and refreshes after successful commits only. Stream
errors are typed `StorageUnavailable` errors; domain command failures retain
their original type. Busy/locked, I/O, disk-full and cannot-open errors allow
retry after the underlying condition is resolved. Malformed storage and unknown
schema versions fail closed. The database is never silently reset.

## Integrity and migrations

Schema v1 stores all domain entities. Current item pointers and immutable item
revisions use deferred foreign keys; session snapshots keep their original item
revision. Removing a group sets current membership to Ungrouped, while historical
snapshots keep their old values. Revisions/operations/ledger/achievements are
append-only through the record API. Mutable rows use UPDATE then INSERT, never
REPLACE, to avoid implicit deletion of related history.

Foreign keys are enabled on every connection. Unique keys protect operations,
Quest/date achievements, completion identities, and a single running **or paused**
session. SQL checks enforce integer storage and nonnegative projections. Commit
checks validate deferred foreign keys and compare wallet/Award projections with
the ledger. Totals use `BigInt` so large intermediate sums cannot wrap. A driver
COMMIT failure closes the uncertain connection, which rolls back any remaining
SQLite transaction; reopen the same file before retrying the operation ID.
`projectionMismatches()` performs a full ledger audit; this initial implementation
also runs it at commit/open, so profile it with realistic histories before tuning
checkpoint frequency or replacing it with an incremental verification strategy.

Add contiguous `SchemaMigration` entries; never edit shipped versions or install
a destructive downgrade callback. All pending migration steps, schema-version
updates and validation execute in one transaction. The SQLite rollback journal
preserves the original database on SQL, integrity or disk failures. No live-file
rename, deletion or replacement occurs. Older nonempty files without a recognized
version and newer schemas are rejected. Keep the database and its journal together
for recovery after a process or device interruption.

The frozen `test/data/fixtures/v1.sql` contains only synthetic records and must
remain unchanged when later migrations are added. Tests independently open that
fixture, upgrade it, inject failing upgrade steps and real `SQLITE_FULL`, and
reopen the original data. Portable backup validation and atomic file replacement
belong to the backup adapter, not this migration API.

Run `flutter test test/data --reporter expanded`. CI additionally runs all domain
and widget tests, analysis, and Android/iOS builds. FFI tests exercise native
SQLite on the host; they do not claim physical-device lifecycle coverage.
