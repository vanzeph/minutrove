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

The record adapters are persistence primitives. `CommandCoordinator` adds shared
idempotent execution, revision guards, and ledger-driven projections; product
command adapters supply history-safe edits, quotes, clock reconciliation, and
goal calculations. Existing domain ports are unchanged.
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

## Atomic command coordinator

Construct `CommandCoordinator(store)` over the same live store used by all
repositories. `execute<T>` takes an operation ID, a `CommandRequest`, a
`committedAt` callback, and an asynchronous action. It checks the saved operation
before running either callback. Matching IDs replay the original durable result,
even after later edits or a restart. A changed command kind, request fingerprint,
or requested result type returns `InvalidInput` without executing the action.
Only successful commands reserve an operation ID. After a storage failure,
resolve the storage condition (reopen the same file if COMMIT was uncertain),
then retry the same ID and arguments.

`CommandRequest.arguments` must include **every** caller-controlled input:
entity IDs, expected revisions, quantity, expense currency/precision/amount, and
explicit conflict choices. Use UUID strings, integer durable units, enum names,
booleans, nulls, lists and string-keyed maps; never use floating-point amounts.
The constructor freezes a SHA-256 digest of versioned canonical JSON. Map order
does not matter; list order, missing fields and explicit nulls do. Exclude current
time, generated record IDs and derived values. Keep request encoding stable when
updating adapters so previously committed operations remain replayable.

Inside the action, the `CommandTransaction` provides:

- `records`: the same transaction for sessions, intervals, remainders, daily
  achievements and notification intents. Do not open another store transaction,
  persist a second operation row, or call an OS/network service from the action.
- `requireItem`, `requireSession`, `requireWallet`, and `requireAward`: read and
  compare expected revisions inside the serialized transaction. A null expected
  Award revision means its pooled balance must not exist. Missing items/sessions
  return `NotFound`; changed revisions return `StaleRevision`.
- `postLedger(entries)`: validate operation attribution, stored item/session
  snapshots and allowance dimensions; append entries and derive wallet and Award
  projections together. Callers provide unique ledger UUIDs and this command's
  operation ID. Domain commands determine the postings after checking their
  business rules against current transactional state. For example, redemption
  calls `requireItem` before deriving the current price and grants. Session
  settlement instead attributes entries to its immutable historical revision.
- `economicState()`: return the final wallet, all pooled balances, active session,
  and this operation's entries/achievements after all related mutations.

Ledger totals are accumulated with `BigInt` and narrowed only after checking
nonnegative signed-64-bit bounds. Wallet deficits report the affected currencies;
allowance deficits report `AllowanceExceeded`; overflow reports `NumericOverflow`.
Each affected projection revision advances once per `postLedger` batch. Quest
time is activity history, not an owned allowance; real budget currencies are
checked individually. Exhausted Awards retain their declared dimensions.

Return a codec-supported value; `execute` detaches it, persists it with the
request fingerprint, and acknowledges only after COMMIT. Economic/session results
are checked against the final saved state so an earlier snapshot cannot be
acknowledged. Any rejection rolls back the operation and every related write.
The store also independently verifies ledger/projection consistency at COMMIT.
Do not catch and suppress failures inside the callback. Every write must be
awaited before returning.

`test/data/command_coordinator_test.dart` includes complete command compositions,
24 concurrent duplicate submissions, replay after reopening, stale and competing
revision checks, currency/allowance limits, and SQL failure injection. The failure
matrix interrupts every write in a composition containing session progress,
remainders, achievement, wallet/allowance postings and notification intent, plus
both sides of COMMIT. It compares the entire recovered database with the original
or fully committed records and then verifies an identical, exactly-once retry.

Run `flutter test test/data --reporter expanded`. CI additionally runs all domain
and widget tests, analysis, and Android/iOS builds. FFI tests exercise native
SQLite on the host; they do not claim physical-device lifecycle coverage.

## Item and group lifecycle

`SqliteItemRepository(store: store, clock: clock, calendar: calendar)` implements
`ItemRepository` over this transaction boundary. Inject the production clock and
reporting calendar used by the other commands. Create with null expected revision;
edit with the last committed revision. The adapter assigns revisions, verifies
current group membership and history, and records the original result with a
canonical JSON request fingerprint. Retry the exact request and operation ID after
an uncertain response; a different request using that ID returns `InvalidInput`.

Use `saveItem` for name, independent icon/color, future configuration, movement,
order, and unarchive (`archived: false`). `archiveItem` refuses an item occupying
the active slot, including pause. Neither operation mutates sessions, ledger,
wallet, accrual remainders or pooled Award allowances. Watches include archived
items so callers can render archived settings and retained Trove balances; apply
Home/Shop filtering in the feature layer.

Use `saveGroup` to create, rename and reorder groups. `removeGroup` increments
member item revisions and moves all current members, including archived ones, to
null/Ungrouped in one transaction. It retains item order and immutable historical
snapshots. A stale item editor cannot restore deleted membership. Equal order
values use the existing stable UUID tie-breaker.

Goal changes append effective dated goal revisions, including disabling a goal.
Changes before today's activity apply today; recorded activity (even with no whole
currency earned), achievements and uncheckpointed running activity defer them to
the next reporting-calendar midnight. Appearance-only edits append no goal
revision. Consumers select the latest effective day and revision for settlement;
`StoreReader.goals` exposes the effective date for configuration feedback. These
commands do not settle or modify an active session.

`flutter test test/data/item_repository_test.dart` verifies these commands with
real SQLite, including persisted duplicate replay and conflicting revisions.
