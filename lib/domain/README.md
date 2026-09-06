# Domain contracts

Import `package:minutrove/domain/domain.dart`. These immutable Dart values and
interfaces are independent of Flutter widgets, SQLite, and notification plugins.
They establish the adapter boundary; concrete persistence, scheduling, and
feature implementations are delivered separately.

`Id<T>` separates UUID identities by entity. Revisions start at one; a null
`expectedRevision` means creation. Repository adapters assign subsequent
revisions. Read history and compare the expected revision inside the transaction
before applying `validateItemEdit`; UI-supplied history flags are not authoritative.

Use `MicroAmount.parse` for virtual currencies and `BudgetAmount.parse` with a
`BudgetCurrency` obtained from pinned `CurrencyMetadata` for real budgets. Never
parse monetary text through `double`. Durable values fit signed 64-bit integers;
intermediate arithmetic uses `BigInt`. Persist the `accrue` remainder alongside
its Quest and currency, including when a session ends. `NumericOverflow` is a
typed failure, not saturation or wraparound.

Every mutating repository call accepts an `OperationId`. Adapters serialize
mutations, validate before writes, commit all related records atomically, and
persist the original result for duplicate replay. Reusing an operation ID with
different arguments is invalid. On failure, neither balances nor history change.
`Result<T>` permits exhaustive `Success`/`Failure` handling. Invalid value
construction throws `DomainError`; command entry points convert it to `Failure`.

`Session` holds an immutable item snapshot and clock anchors. Running and paused
sessions occupy the same global slot. A conflict choice must originate in an
explicit user action. `ReportingCalendar` resolves pinned IANA rules and midnight
boundaries; `EventTime` freezes a consistent UTC/offset/day assignment.

`NotificationIntent` represents a durable desired schedule (null deadline means
cancel). Notification adapters reconcile stable IDs and persisted completion
identities; notification denial must not roll back economic completion.

Backup bytes and previews are immutable. `inspectBackup` validates a temporary
copy; `restoreBackup` requires a confirmation tied to the source digest. Adapter
implementations must validate again, preserve a safety copy and use an atomic
replacement. Neither a successful preview nor an in-memory model constructor is
sufficient database/backup integrity validation.

Tests include numeric boundaries, split-session precision, history-preserving
edit rules, immutable snapshots, metric compatibility, and fake adapter consumers.
