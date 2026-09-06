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

## Session commands

`SqliteSessionRepository(store: store, clock: clock, calendar: calendar)` implements
the existing `SessionRepository` port. Use the same live store and injected clock
and calendar as other commands. Starts capture the current immutable item revision,
reporting zone, Quest countdown or pooled Award time, clock anchors, and stable
completion identity. A paused session owns the global slot. Repeated starts of the
same active item return that session, including when paused; a different item
requires the explicit conflict choice. Replacement validates the new start and
settles the old session in the same transaction, so a failure preserves both the
old session and its economics.

Keep an operation ID and its original arguments for retries. A duplicate returns
its original durable result before checking the current clock or revisions, even
if that session has since finished. New commands must use the latest expected
revision. Pause on paused, resume on running, and end/reconcile on terminal sessions
are harmless no-ops; pause/resume on terminal sessions are typed invalid transitions.
Use `reconcileSession` for checkpoints and lifecycle callbacks, not a monetary
write on every UI tick. Reads/watches report committed state; `advanceSession` is
a pure projection available for countdown presentation.

Settlement writes only newly active milliseconds, frozen day assignments, both
currency remainders, ledger postings, projections, session progress and notification
intent in one transaction. Paused time contributes zero. Reaching the duration
completes even when triggered by pause/end, caps late callbacks, and clears the
slot. Early end retains exact earnings or unused Award time. Purchases during a
timed Award do not extend the current run; the extra allowance remains available
for the next run. Archived purchased Awards can still use their retained time.

`SessionSettlement(calendar).apply` composes the same settlement inside an existing
`CommandTransaction`, for example before recording an explicitly confirmed expense
conflict. Supply a freshly read session and the command's single clock reading;
do not open another transaction or call a repository from its callback. Daily-goal
bonuses settle in this same transaction. Native notification/lifecycle adapters
consume the committed session and notification intent separately.
The session command persists schedule/cancel intents and preserves an existing
`completionChimeHandled` flag; an OS adapter owns playback and marking it handled.
An operation replay is historical evidence and must not independently trigger sound.

Same-boot elapsed time uses monotonic anchors, including across reopen. Across a
boot change, the pure projection clamps the wall-time estimate to zero/remaining
duration and exposes `clockDiscontinuity` for lifecycle diagnostics. Interval clock
endpoints represent the allocated accounting timeline; after a clock edit or reboot
they are estimates, not additional device-clock samples. The injected calendar
splits that timeline at actual local midnight. The native clock and lifecycle
adapters are documented in [session recovery](../platform/sessions/README.md).
All clock consumers await `FutureOr<ClockReading>` after operation replay lookup;
a native sample failure leaves the command transaction unchanged. Notification
scheduling and physical-device validation remain separate integrations.

`flutter test test/data/session_repository_test.dart` exercises exact earnings,
fractional carry, pooled Award consumption, snapshots, conflicts, concurrent
submissions, durable replay, and every write/COMMIT failure boundary of an atomic
session replacement. Domain tests cover bounded clock recovery and a 23-hour day.

## Award pack redemption

`SqliteAwardRedemptionRepository(store: store, clock: clock, calendar: calendar)`
provides the purchase and read methods of `EconomyRepository`. Compose it with the
same live store as item/session commands; the complete economy adapter delegates
`watchWallet`, `watchAwards`, `previewAward`, and `redeemAward` to it and supplies
expense/session settlement separately. No schema or domain port changes are
required. Ledger IDs default to random UUIDs; tests may inject a UUID factory.

`previewAward` reads the current item, wallet and pooled allowance in one snapshot.
Its quote contains the item revision, exact joint price, grants, remaining wallet,
and wallet-based maximum affordable whole-pack quantity. Per-purchase and pooled
allowance arithmetic must also fit durable integer bounds. Preview creates no
operation, session or ledger record; cancellation discards it. Read failures stay
`StorageUnavailable`; business rejections retain their typed errors.

Pass that quote's revision as `expectedRevision` to `redeemAward`. Confirmation
rechecks the current item and balances inside `CommandCoordinator`, posts both
required currency debits and every grant in one batch, and adds to one allowance
row per Award. A stale revision returns `StaleRevision`; request a new preview and
user confirmation. Changed wallet funds are checked at confirmation. Archived
Awards cannot be purchased, but their existing allowances remain observable.
Purchases during running or paused sessions preserve the session and notification
intent. Watches include exhausted balances; Home filters `isExhausted`.

Keep the same operation ID and exact arguments for a retry after an uncertain
response. Matching duplicates return the original committed `EconomicState`,
even after later purchases, definition edits, archive or restart. A different
Award, revision or quantity with that ID returns `InvalidInput`. Failures reserve
no ID and change neither wallet, allowance nor history.

`flutter test test/data/award_redemption_repository_test.dart` covers the 45 + 30
= 75 minute example, every price/grant dimension combination, affordability,
stale quotes, concurrent purchases, durable replay, signed-64-bit limits and
failure at every purchase write and both COMMIT boundaries. All fixtures are
synthetic. These adapter tests do not claim UI or physical-device coverage.

## Daily goals and calendar attribution

Use `IanaReportingCalendar()` for item, session, settings and economic commands.
It loads the full offline database in the locked timezone package (2025c rules),
validates zone membership, and assigns UTC instants to local dates and offsets.
`nextMidnight` follows actual offset transitions, including 23/25-hour days,
half-hour daylight saving, missing/repeated midnight and skipped calendar dates.
It does not use the machine's current zone. Supply the device's IANA identifier
in `initialSettings` when creating the store; reopening preserves stored settings.
Later timezone rule updates arrive with a reviewed application dependency update.

`SqliteSettingsRepository` implements `SettingsRepository` over the same command
queue. A zone edit checks the expected settings revision and IANA membership,
persists the new revision and original operation result atomically, and affects
new sessions and operations only. Running and paused sessions keep their zone;
historical intervals, event dates, offsets and achievements remain unchanged.
Retries use the original operation ID, zone and expected revision.

Session settlement selects each day's latest effective goal revision, including
disabling revisions. It sums committed Quest time with the new active intervals
and inserts at most one achievement per Quest/date together with ordinary
earnings, bonuses, remainders and session progress. The existing SQL unique key
is the final duplicate guard, independent of zone or goal revision. A zero bonus
still records achievement; reaching the target never stops ordinary earnings.
At an exact midnight threshold, the bonus is attributed to the last active
millisecond of the completed day so the next date cannot receive its reward.

Item edits inspect uncheckpointed activity using the same monotonic session
projection as settlement. A wall-clock correction cannot make already active
time disappear from the effective-date check. Appearance/rate edits retain the
existing session snapshot; goal revisions can take effect on a later date within
that session. No schema change or historical reattribution is performed.

`daily_goals_repository_test.dart` exercises the complete SQLite commands through
cumulative sessions, pauses, midnight, both DST directions, travel, prospective
zone changes, disabling/re-enabling goals, duplicate callbacks and file reopen.
Its fault matrix interrupts each two-day settlement write and both sides of
COMMIT, then verifies a whole-database rollback or original committed replay.
`reporting_calendar_test.dart` verifies actual IANA transitions. These tests use
synthetic records and do not assert physical-device lifecycle or UI acceptance.

## Award consumption

`SqliteEconomyRepository(store: store, clock: clock, calendar: calendar)` implements
all of `EconomyRepository`, delegating purchase/read commands to the existing
redemption adapter. Compose it with `SqliteSessionRepository` over the same store.
Timed use starts from the pooled time, pauses without consumption, and settles
only active milliseconds on early end or completion; new purchases do not extend
an existing run. No consumption command refunds Coins or Gems.

`recordExpense` accepts a `BudgetAmount` parsed with pinned currency metadata and
the last observed **balance** revision. It requires a positive expense in the same
currency and precision, within the remaining budget. Validation failures and
stale revisions have no effect. Archived purchased allowances remain spendable.
The expense uses the current item revision for history and the current reporting
zone; an existing session keeps its own snapshot and zone.

A running or paused session returns `ActiveSessionConflict` for `cancel`, even
when it belongs to the same Award. Only an explicit user choice may supply
`endCurrentAndContinue`. That command settles the old session, cancels its durable
notification intent, posts the expense, and returns the final economy in one
transaction. Validate the observed balance revision before same-Award settlement
advances it. Retry the original operation ID and every original argument after an
uncertain response; duplicate replay returns the original result without another
clock read or settlement. Refresh state and request a fresh confirmation after a
stale revision. Notification adapters reconcile the committed intent separately.

Use `awardConsumptionActions(balance)` for Home routing: two positive dimensions
present Use time / Record expense; one remaining dimension offers that action;
exhaustion offers neither. Routing is read-only, and command validation remains
authoritative. Watches retain exhausted rows and archived balances; Home filters
`isExhausted`. Definition/history survive exhaustion and a later purchase refills
the same row.

`flutter test test/data/economy_repository_test.dart` exercises actual earn → buy
→ consume commands, exact expense arithmetic, both consumption orders, paused
conflicts, same-Award settlement, stale/concurrent requests, restart replay,
archived allowances, and every SQL write/COMMIT failure boundary for both Quest
and Award conflict settlement. These synthetic SQLite tests cover command and
routing behavior; downstream feature/device tasks verify the native UI.
