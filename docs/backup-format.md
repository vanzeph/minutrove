# Portable backups (version 1)

A `.minutrove` backup is **unencrypted** UTF-8 JSON. Anyone with the file can read
item names, activity, amounts and settings. Store and share it accordingly. The
export UI must disclose this before offering the native file picker/share sheet.
There is no account, network request, automatic sync, merge or executable content.
The export adapter returns bytes; native file selection and replacement belong
to the settings/restore integration.

`SqliteBackupExporter(store: store, clock: clock).exportBackup(operationId: id)`
uses the same store queue as all commands. It checks for a running **or paused**
session before sampling the clock or loading history. `ActiveSessionConflict`
does not pause, end, reconcile or settle the session, even past its deadline.
The user must explicitly end it first. Export reads and serializes one SQLite
transaction snapshot, including any writes queued before it and excluding those
queued after it. It creates no operation/notification row and no temporary file.
The operation ID is a caller correlation value for this read, not a durable
mutation ID. Retrying reads current data; unchanged data and date yield identical
bytes. The returned `BackupFile` is immutable.

## Envelope and integrity

The object has exactly `format`, `version`, `payload`, and `integrity` fields:

- `format` is `minutrove`; `version` is the JSON integer `1`.
- `payload` contains `createdUtc` (UTC ISO-8601), `sourceSchemaVersion` (JSON
  integer), `currencyMetadataVersion` (pinned metadata identifier), `recordCounts`
  (collection name to JSON integer count), and `records`.
- `integrity` contains `algorithm: "sha256"`, `payloadBytes` (JSON integer UTF-8
  byte length), and `sha256` (64 lowercase hexadecimal digits).

All objects use recursively sorted keys and compact JSON without whitespace or
a trailing newline. Array order is significant. Strings use Dart's standard JSON
escaping and direct UTF-8 for non-ASCII characters. The integrity digest covers
the canonical **payload**, including source date, versions and counts. The
preview's `sha256` instead identifies the **entire file**, for later replacement
confirmation. SHA-256 detects accidental corruption; an unsigned file does not
authenticate its author or prevent deliberate editing.

Every integer inside a record is a **decimal string**, including amounts,
milliseconds, revisions, ARGB colors, UTC epoch milliseconds and offsets. Its
grammar is `0` or `-?[1-9][0-9]*`, within signed 64-bit range. There are no JSON
floating-point numbers in records. Use an exact signed-64-bit/BigInt parser;
never parse balances via double. Coins/Gems use millionths, time uses
milliseconds, and real budget values use their stored ISO currency and minor-unit
precision. Null allowance dimensions remain distinct from zero.

## Logical records

`records` contains all twelve collections below, even when empty. Wallet and
settings each contain exactly one record. Other top-level collections retain
stable primary-key order; goals use item ID, effective date and revision,
achievements use day and item ID, and session intervals retain their ordinal.

| Collection | Record tag | Contents |
| --- | --- | --- |
| `groups` | `group` | Current groups, revisions and ordering |
| `items` | `item` | Current definitions, membership, ordering and archive state |
| `itemRevisions` | `itemRevision` | Every immutable item/configuration snapshot and recorded event time |
| `sessions` | `session` | Ended/completed sessions, original item snapshot, settled time, completion identity and every active interval |
| `operations` | `operation` | Every committed ID, kind, original request fingerprint, event time and portable product result |
| `ledger` | `ledger` | Every signed posting, operation/item/revision/session reference, dimension and event assignment |
| `wallet` | `wallet` | Exact wallet amounts and revision |
| `awardBalances` | `balance` | All pooled balances, including archived/exhausted Awards |
| `accrualRemainders` | `remainder` | Persisted Quest/currency division remainders |
| `goalRevisions` | `goalRevision` | Every effective goal revision, including disabled goals |
| `achievements` | `achievement` | Paid Quest/date identities, goal revision, operation, event time and bonus |
| `settings` | `settings` | Reporting zone and revision |

Every record is tagged by `type`. The frozen explicit field allowlist is in
[`backup_codec.dart`](../lib/data/backup_codec.dart); the corresponding typed
export mapping is in [`backup_record_codec.dart`](../lib/data/backup_record_codec.dart).
The independent, synthetic
[`portable-v1.minutrove`](../test/data/fixtures/portable-v1.minutrove) fixture
contains every collection and is a compatibility gate. This logical format is
separate from SQL column layout and internal `RecordCodec` JSON. Changing the
internal codec must not silently change this contract. New portable versions
need explicit version dispatch/converters and retained compatibility fixtures.

Event times retain original UTC, day key, IANA zone and offset. Historical group
IDs may refer to removed groups; current membership remains Ungrouped. Never
rewrite historical snapshots to match today's layout or timezone.

Device boot IDs, monotonic clock anchors, run deadlines, notification scheduling
and playback state are omitted everywhere, including nested operation results.
Clock endpoints become `instant` records containing only UTC. A session mutation
result contains its session and economy, without its notification intent.
Historical operation results retain their original product status (which may
have been running/paused), quantities, balances, revisions and request fingerprint;
they are replay/history data, **never rows to install in the active-session slot**.
Only the top-level ended/completed sessions become restored durable history.
Restore must supply inert local clock placeholders and cancellation-only
notification handling as needed by its internal adapters. It must never schedule
from historical replay results. Original fingerprints must be preserved exactly
(some existing commands use a JSON fingerprint, others a SHA-256 digest).

No credentials, database filenames, OS paths, arbitrary runtime objects or shell
commands are read by export. User-entered text remains data, even if it happens
to look like a path; it must never be executed or used as a destination filename.

## Bounds and failure behavior

Defaults are 64 MiB per complete file, 1 MiB per logical record, 250,000 records,
and 32 record nesting levels. The source preflight counts all selected SQLite
rows, including intervals; it sums stored column byte sizes plus 64 bytes per row
and checks individual source row sizes before materializing JSON/history. It
then checks relationships and ledger/projection consistency. Unsupported source
schemas fail closed; the exporter supports database schemas 1 and 2.

Source rows are fetched in pages of 128; per-record and cumulative output budgets
are checked while collecting. Final encoding uses a bounded UTF-8 sink. The
snapshot and final bytes are in memory, so peak memory exceeds the file limit;
this is bounded export, not a streaming file writer. Large histories exceeding a
limit return `InvalidBackup` without a partial file or changes to data. Limits
can be lowered for constrained environments; increasing published limits needs
explicit compatibility/resource validation.

`BackupCodec.decode` checks the byte/depth bounds before JSON parsing, rejects
noncanonical/duplicate-key JSON, verifies envelope integrity and record counts,
and checks the field allowlist and exact numeric syntax. Newer versions return
`UnsupportedBackupVersion`. Storage/clock failures return `StorageUnavailable`;
errors never include file content. All these paths retain original data.

Decoding is **not restore approval or full semantic validation**. The restore
adapter must additionally validate supported currency metadata, value ranges,
record types in each relationship, uniqueness, dates, revisions and economic
invariants in a temporary database. It must bind explicit replacement confirmation
to the whole-file digest, preserve a safety copy, replace atomically, cancel stale
notifications and reopen successfully. Export provides no live-file replacement
API. Native sharing, cross-device restore and interrupted replacement are separate
acceptance gates; codec round-trip tests do not claim those passed.
