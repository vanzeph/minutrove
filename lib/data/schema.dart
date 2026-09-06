import 'package:sqflite_common/sqlite_api.dart';

/// Migrations are cumulative, contiguous, and run in one SQLite transaction.
/// Never use a downgrade/delete-and-recreate callback for user data.
final class SchemaMigration {
  const SchemaMigration(this.version, this.apply);
  final int version;
  final Future<void> Function(Transaction transaction) apply;
}

final List<SchemaMigration> schemaMigrations = List.unmodifiable([
  SchemaMigration(1, (transaction) async {
    for (final statement in schemaV1) {
      await transaction.execute(statement);
    }
  }),
  SchemaMigration(2, (transaction) async {
    await transaction.execute(
      'CREATE INDEX achievements_by_day ON daily_achievements(day, quest_id)',
    );
  }),
]);

// Avoid newer SQLite-only syntax: native sqflite uses the OS SQLite library.
// typeof guards stop SQLite from silently promoting overflowing integers to REAL.
const schemaV1 = <String>[
  '''CREATE TABLE schema_version (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    version INTEGER NOT NULL CHECK (version >= 1)
  )''',
  '''CREATE TABLE groups (
    id TEXT PRIMARY KEY NOT NULL,
    revision INTEGER NOT NULL CHECK (typeof(revision) = 'integer' AND revision > 0),
    name TEXT NOT NULL CHECK (length(trim(name)) > 0),
    sort_order INTEGER NOT NULL CHECK (typeof(sort_order) = 'integer' AND sort_order >= 0)
  )''',
  '''CREATE TABLE items (
    id TEXT PRIMARY KEY NOT NULL,
    revision INTEGER NOT NULL CHECK (typeof(revision) = 'integer' AND revision > 0),
    group_id TEXT REFERENCES groups(id) ON DELETE SET NULL,
    sort_order INTEGER NOT NULL CHECK (typeof(sort_order) = 'integer' AND sort_order >= 0),
    archived INTEGER NOT NULL CHECK (archived IN (0, 1)),
    FOREIGN KEY (id, revision) REFERENCES item_revisions(item_id, revision)
      DEFERRABLE INITIALLY DEFERRED
  )''',
  '''CREATE TABLE item_revisions (
    item_id TEXT NOT NULL REFERENCES items(id) DEFERRABLE INITIALLY DEFERRED,
    revision INTEGER NOT NULL CHECK (typeof(revision) = 'integer' AND revision > 0),
    type TEXT NOT NULL CHECK (type IN ('quest', 'award')),
    snapshot TEXT NOT NULL,
    recorded_utc INTEGER NOT NULL CHECK (typeof(recorded_utc) = 'integer'),
    recorded_day TEXT NOT NULL,
    recorded_zone TEXT NOT NULL,
    recorded_offset INTEGER NOT NULL CHECK (recorded_offset BETWEEN -86400 AND 86400),
    PRIMARY KEY (item_id, revision)
  )''',
  '''CREATE TABLE operations (
    id TEXT PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL,
    request_fingerprint TEXT NOT NULL CHECK (length(request_fingerprint) > 0),
    result TEXT NOT NULL,
    committed_utc INTEGER NOT NULL CHECK (typeof(committed_utc) = 'integer'),
    committed_day TEXT NOT NULL,
    committed_zone TEXT NOT NULL,
    committed_offset INTEGER NOT NULL CHECK (committed_offset BETWEEN -86400 AND 86400)
  )''',
  '''CREATE TABLE sessions (
    id TEXT PRIMARY KEY NOT NULL,
    revision INTEGER NOT NULL CHECK (typeof(revision) = 'integer' AND revision > 0),
    item_id TEXT NOT NULL,
    item_revision INTEGER NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('running', 'paused', 'completed', 'ended')),
    zone TEXT NOT NULL,
    started_clock TEXT NOT NULL,
    checkpoint_clock TEXT NOT NULL,
    duration_ms INTEGER NOT NULL CHECK (typeof(duration_ms) = 'integer' AND duration_ms > 0),
    settled_ms INTEGER NOT NULL CHECK (typeof(settled_ms) = 'integer' AND settled_ms BETWEEN 0 AND duration_ms),
    deadline_utc INTEGER CHECK (deadline_utc IS NULL OR typeof(deadline_utc) = 'integer'),
    completion_id TEXT NOT NULL UNIQUE,
    UNIQUE (id, completion_id),
    FOREIGN KEY (item_id, item_revision) REFERENCES item_revisions(item_id, revision),
    CHECK ((status = 'running') = (deadline_utc IS NOT NULL)),
    CHECK (status != 'completed' OR settled_ms = duration_ms)
  )''',
  '''CREATE UNIQUE INDEX one_active_session ON sessions ((1))
    WHERE status IN ('running', 'paused')''',
  '''CREATE TABLE active_intervals (
    session_id TEXT NOT NULL REFERENCES sessions(id),
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    started_clock TEXT NOT NULL,
    ended_clock TEXT NOT NULL,
    active_ms INTEGER NOT NULL CHECK (typeof(active_ms) = 'integer' AND active_ms >= 0),
    assigned_utc INTEGER NOT NULL CHECK (typeof(assigned_utc) = 'integer'),
    assigned_day TEXT NOT NULL,
    assigned_zone TEXT NOT NULL,
    assigned_offset INTEGER NOT NULL CHECK (assigned_offset BETWEEN -86400 AND 86400),
    PRIMARY KEY (session_id, ordinal)
  )''',
  '''CREATE TABLE ledger_entries (
    id TEXT PRIMARY KEY NOT NULL,
    operation_id TEXT NOT NULL REFERENCES operations(id) DEFERRABLE INITIALLY DEFERRED,
    item_id TEXT NOT NULL,
    item_revision INTEGER NOT NULL,
    session_id TEXT REFERENCES sessions(id),
    dimension TEXT NOT NULL CHECK (dimension IN ('coins', 'gems', 'time', 'budget')),
    budget_currency TEXT,
    budget_digits INTEGER,
    delta INTEGER NOT NULL CHECK (typeof(delta) = 'integer'),
    assigned_utc INTEGER NOT NULL CHECK (typeof(assigned_utc) = 'integer'),
    assigned_day TEXT NOT NULL,
    assigned_zone TEXT NOT NULL,
    assigned_offset INTEGER NOT NULL CHECK (assigned_offset BETWEEN -86400 AND 86400),
    FOREIGN KEY (item_id, item_revision) REFERENCES item_revisions(item_id, revision),
    CHECK ((dimension = 'budget' AND budget_currency IS NOT NULL AND
      length(budget_currency) = 3 AND budget_digits IS NOT NULL AND budget_digits BETWEEN 0 AND 4)
      OR (dimension != 'budget' AND budget_currency IS NULL AND budget_digits IS NULL))
  )''',
  'CREATE INDEX ledger_by_day ON ledger_entries(assigned_day, dimension, item_id)',
  'CREATE INDEX ledger_by_operation ON ledger_entries(operation_id)',
  'CREATE INDEX sessions_by_item ON sessions(item_id)',
  '''CREATE TABLE wallet_projection (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    revision INTEGER NOT NULL CHECK (typeof(revision) = 'integer' AND revision > 0),
    coins INTEGER NOT NULL CHECK (typeof(coins) = 'integer' AND coins >= 0),
    gems INTEGER NOT NULL CHECK (typeof(gems) = 'integer' AND gems >= 0)
  )''',
  'INSERT INTO wallet_projection VALUES (1, 1, 0, 0)',
  '''CREATE TABLE award_balances (
    award_id TEXT PRIMARY KEY NOT NULL REFERENCES items(id),
    revision INTEGER NOT NULL CHECK (typeof(revision) = 'integer' AND revision > 0),
    time_ms INTEGER CHECK (time_ms IS NULL OR (typeof(time_ms) = 'integer' AND time_ms >= 0)),
    budget_minor INTEGER CHECK (budget_minor IS NULL OR (typeof(budget_minor) = 'integer' AND budget_minor >= 0)),
    budget_currency TEXT,
    budget_digits INTEGER,
    CHECK (time_ms IS NOT NULL OR budget_minor IS NOT NULL),
    CHECK ((budget_minor IS NULL AND budget_currency IS NULL AND budget_digits IS NULL) OR
      (budget_minor IS NOT NULL AND budget_currency IS NOT NULL AND length(budget_currency) = 3
       AND budget_digits IS NOT NULL AND budget_digits BETWEEN 0 AND 4))
  )''',
  '''CREATE TABLE quest_accrual_remainders (
    quest_id TEXT NOT NULL REFERENCES items(id),
    currency TEXT NOT NULL CHECK (currency IN ('coins', 'gems')),
    remainder INTEGER NOT NULL CHECK (typeof(remainder) = 'integer' AND remainder BETWEEN 0 AND 3599999),
    PRIMARY KEY (quest_id, currency)
  )''',
  '''CREATE TABLE daily_goal_revisions (
    quest_id TEXT NOT NULL REFERENCES items(id),
    revision INTEGER NOT NULL CHECK (typeof(revision) = 'integer' AND revision > 0),
    effective_day TEXT NOT NULL,
    zone TEXT NOT NULL,
    target_ms INTEGER CHECK (target_ms IS NULL OR (typeof(target_ms) = 'integer' AND target_ms > 0 AND target_ms % 1000 = 0)),
    bonus_coins INTEGER NOT NULL CHECK (typeof(bonus_coins) = 'integer' AND bonus_coins >= 0),
    bonus_gems INTEGER NOT NULL CHECK (typeof(bonus_gems) = 'integer' AND bonus_gems >= 0),
    CHECK (target_ms IS NOT NULL OR (bonus_coins = 0 AND bonus_gems = 0)),
    PRIMARY KEY (quest_id, revision)
  )''',
  '''CREATE TABLE daily_achievements (
    quest_id TEXT NOT NULL,
    day TEXT NOT NULL,
    goal_revision INTEGER NOT NULL,
    operation_id TEXT NOT NULL REFERENCES operations(id) DEFERRABLE INITIALLY DEFERRED,
    awarded_utc INTEGER NOT NULL CHECK (typeof(awarded_utc) = 'integer'),
    awarded_day TEXT NOT NULL,
    awarded_zone TEXT NOT NULL,
    awarded_offset INTEGER NOT NULL CHECK (awarded_offset BETWEEN -86400 AND 86400),
    bonus_coins INTEGER NOT NULL CHECK (typeof(bonus_coins) = 'integer' AND bonus_coins >= 0),
    bonus_gems INTEGER NOT NULL CHECK (typeof(bonus_gems) = 'integer' AND bonus_gems >= 0),
    PRIMARY KEY (quest_id, day),
    FOREIGN KEY (quest_id, goal_revision) REFERENCES daily_goal_revisions(quest_id, revision)
  )''',
  '''CREATE TABLE app_settings (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    revision INTEGER NOT NULL CHECK (typeof(revision) = 'integer' AND revision > 0),
    reporting_zone TEXT NOT NULL CHECK (length(reporting_zone) > 0)
  )''',
  '''CREATE TABLE notification_intents (
    session_id TEXT PRIMARY KEY NOT NULL,
    session_revision INTEGER NOT NULL CHECK (typeof(session_revision) = 'integer' AND session_revision > 0),
    completion_id TEXT NOT NULL UNIQUE,
    deadline_utc INTEGER CHECK (deadline_utc IS NULL OR typeof(deadline_utc) = 'integer'),
    chime_handled INTEGER NOT NULL CHECK (chime_handled IN (0, 1)),
    FOREIGN KEY (session_id, completion_id) REFERENCES sessions(id, completion_id)
  )''',
];
