-- Frozen schema v1 with entirely synthetic records. Do not regenerate for later migrations.
PRAGMA user_version = 1;
CREATE TABLE active_intervals (
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
  );
INSERT INTO "active_intervals" VALUES('00000000-0000-4000-8000-000000000004',0,'{"type":"clock","utc":1768478400000,"boot":"fixture-boot","monotonic":1000}','{"type":"clock","utc":1768478410000,"boot":"fixture-boot","monotonic":11000}',10000,1768478400000,'2026-01-15','Etc/UTC',0);
CREATE TABLE app_settings (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    revision INTEGER NOT NULL CHECK (typeof(revision) = 'integer' AND revision > 0),
    reporting_zone TEXT NOT NULL CHECK (length(reporting_zone) > 0)
  );
INSERT INTO "app_settings" VALUES(1,1,'Etc/UTC');
CREATE TABLE award_balances (
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
  );
INSERT INTO "award_balances" VALUES('00000000-0000-4000-8000-000000000002',1,60000,1000,'USD',2);
CREATE TABLE daily_achievements (
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
  );
INSERT INTO "daily_achievements" VALUES('00000000-0000-4000-8000-000000000001','2026-01-15',1,'00000000-0000-4000-8000-000000000005',1768478400000,'2026-01-15','Etc/UTC',0,10,0);
CREATE TABLE daily_goal_revisions (
    quest_id TEXT NOT NULL REFERENCES items(id),
    revision INTEGER NOT NULL CHECK (typeof(revision) = 'integer' AND revision > 0),
    effective_day TEXT NOT NULL,
    zone TEXT NOT NULL,
    target_ms INTEGER CHECK (target_ms IS NULL OR (typeof(target_ms) = 'integer' AND target_ms > 0 AND target_ms % 1000 = 0)),
    bonus_coins INTEGER NOT NULL CHECK (typeof(bonus_coins) = 'integer' AND bonus_coins >= 0),
    bonus_gems INTEGER NOT NULL CHECK (typeof(bonus_gems) = 'integer' AND bonus_gems >= 0),
    CHECK (target_ms IS NOT NULL OR (bonus_coins = 0 AND bonus_gems = 0)),
    PRIMARY KEY (quest_id, revision)
  );
INSERT INTO "daily_goal_revisions" VALUES('00000000-0000-4000-8000-000000000001',1,'2026-01-15','Etc/UTC',60000,10,0);
CREATE TABLE groups (
    id TEXT PRIMARY KEY NOT NULL,
    revision INTEGER NOT NULL CHECK (typeof(revision) = 'integer' AND revision > 0),
    name TEXT NOT NULL CHECK (length(trim(name)) > 0),
    sort_order INTEGER NOT NULL CHECK (typeof(sort_order) = 'integer' AND sort_order >= 0)
  );
INSERT INTO "groups" VALUES('00000000-0000-4000-8000-000000000003',1,'Synthetic Group',0);
CREATE TABLE item_revisions (
    item_id TEXT NOT NULL REFERENCES items(id) DEFERRABLE INITIALLY DEFERRED,
    revision INTEGER NOT NULL CHECK (typeof(revision) = 'integer' AND revision > 0),
    type TEXT NOT NULL CHECK (type IN ('quest', 'award')),
    snapshot TEXT NOT NULL,
    recorded_utc INTEGER NOT NULL CHECK (typeof(recorded_utc) = 'integer'),
    recorded_day TEXT NOT NULL,
    recorded_zone TEXT NOT NULL,
    recorded_offset INTEGER NOT NULL CHECK (recorded_offset BETWEEN -86400 AND 86400),
    PRIMARY KEY (item_id, revision)
  );
INSERT INTO "item_revisions" VALUES('00000000-0000-4000-8000-000000000001',1,'quest','{"type":"item","id":"00000000-0000-4000-8000-000000000001","revision":1,"name":"Synthetic Quest","icon":"gamepad","color":4287116134,"group":"00000000-0000-4000-8000-000000000003","order":0,"archived":false,"config":{"type":"quest","duration":60000,"rates":{"type":"amounts","coins":1000000,"gems":0},"goal":{"type":"goal","target":60000,"bonus":{"type":"amounts","coins":10,"gems":0}}}}',1768478400000,'2026-01-15','Etc/UTC',0);
INSERT INTO "item_revisions" VALUES('00000000-0000-4000-8000-000000000002',1,'award','{"type":"item","id":"00000000-0000-4000-8000-000000000002","revision":1,"name":"Synthetic Combined Award","icon":"gamepad","color":4287116134,"group":null,"order":1,"archived":false,"config":{"type":"award","pack":"Pack","step":1,"price":{"type":"amounts","coins":20,"gems":0},"time":60000,"budget":{"type":"budget","currency":"USD","digits":2,"minor":1000}}}',1768478400000,'2026-01-15','Etc/UTC',0);
CREATE TABLE items (
    id TEXT PRIMARY KEY NOT NULL,
    revision INTEGER NOT NULL CHECK (typeof(revision) = 'integer' AND revision > 0),
    group_id TEXT REFERENCES groups(id) ON DELETE SET NULL,
    sort_order INTEGER NOT NULL CHECK (typeof(sort_order) = 'integer' AND sort_order >= 0),
    archived INTEGER NOT NULL CHECK (archived IN (0, 1)),
    FOREIGN KEY (id, revision) REFERENCES item_revisions(item_id, revision)
      DEFERRABLE INITIALLY DEFERRED
  );
INSERT INTO "items" VALUES('00000000-0000-4000-8000-000000000001',1,'00000000-0000-4000-8000-000000000003',0,0);
INSERT INTO "items" VALUES('00000000-0000-4000-8000-000000000002',1,NULL,1,0);
CREATE TABLE ledger_entries (
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
  );
INSERT INTO "ledger_entries" VALUES('00000000-0000-4000-8000-000000000006','00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000001',1,NULL,'coins',NULL,NULL,100,1768478400000,'2026-01-15','Etc/UTC',0);
INSERT INTO "ledger_entries" VALUES('00000000-0000-4000-8000-000000000007','00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000001',1,NULL,'gems',NULL,NULL,2,1768478400000,'2026-01-15','Etc/UTC',0);
INSERT INTO "ledger_entries" VALUES('00000000-0000-4000-8000-000000000008','00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000002',1,NULL,'time',NULL,NULL,60000,1768478400000,'2026-01-15','Etc/UTC',0);
INSERT INTO "ledger_entries" VALUES('00000000-0000-4000-8000-000000000009','00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000002',1,NULL,'budget','USD',2,1000,1768478400000,'2026-01-15','Etc/UTC',0);
CREATE TABLE notification_intents (
    session_id TEXT PRIMARY KEY NOT NULL,
    session_revision INTEGER NOT NULL CHECK (typeof(session_revision) = 'integer' AND session_revision > 0),
    completion_id TEXT NOT NULL UNIQUE,
    deadline_utc INTEGER CHECK (deadline_utc IS NULL OR typeof(deadline_utc) = 'integer'),
    chime_handled INTEGER NOT NULL CHECK (chime_handled IN (0, 1)),
    FOREIGN KEY (session_id, completion_id) REFERENCES sessions(id, completion_id)
  );
INSERT INTO "notification_intents" VALUES('00000000-0000-4000-8000-000000000004',1,'00000000-0000-4000-8000-000000000104',1768478460000,0);
CREATE TABLE operations (
    id TEXT PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL,
    request_fingerprint TEXT NOT NULL CHECK (length(request_fingerprint) > 0),
    result TEXT NOT NULL,
    committed_utc INTEGER NOT NULL CHECK (typeof(committed_utc) = 'integer'),
    committed_day TEXT NOT NULL,
    committed_zone TEXT NOT NULL,
    committed_offset INTEGER NOT NULL CHECK (committed_offset BETWEEN -86400 AND 86400)
  );
INSERT INTO "operations" VALUES('00000000-0000-4000-8000-000000000005','reconcileSession','synthetic-request-5','{"type":"economy","operation":"00000000-0000-4000-8000-000000000005","wallet":{"type":"wallet","revision":2,"balances":{"type":"amounts","coins":100,"gems":2}},"awards":[{"type":"balance","id":"00000000-0000-4000-8000-000000000002","revision":1,"time":60000,"budget":{"type":"budget","currency":"USD","digits":2,"minor":1000}}],"session":{"type":"session","id":"00000000-0000-4000-8000-000000000004","revision":1,"item":{"type":"item","id":"00000000-0000-4000-8000-000000000001","revision":1,"name":"Synthetic Quest","icon":"gamepad","color":4287116134,"group":"00000000-0000-4000-8000-000000000003","order":0,"archived":false,"config":{"type":"quest","duration":60000,"rates":{"type":"amounts","coins":1000000,"gems":0},"goal":{"type":"goal","target":60000,"bonus":{"type":"amounts","coins":10,"gems":0}}}},"status":"running","zone":"Etc/UTC","start":{"type":"clock","utc":1768478400000,"boot":"fixture-boot","monotonic":1000},"checkpoint":{"type":"clock","utc":1768478410000,"boot":"fixture-boot","monotonic":11000},"duration":60000,"settled":10000,"deadline":1768478460000,"completion":"00000000-0000-4000-8000-000000000104","intervals":[{"type":"interval","start":{"type":"clock","utc":1768478400000,"boot":"fixture-boot","monotonic":1000},"end":{"type":"clock","utc":1768478410000,"boot":"fixture-boot","monotonic":11000},"active":10000,"at":{"type":"event","utc":1768478400000,"day":"2026-01-15","zone":"Etc/UTC","offset":0}}]},"entries":[{"type":"ledger","id":"00000000-0000-4000-8000-000000000006","operation":"00000000-0000-4000-8000-000000000005","item":"00000000-0000-4000-8000-000000000001","revision":1,"session":null,"at":{"type":"event","utc":1768478400000,"day":"2026-01-15","zone":"Etc/UTC","offset":0},"dimension":{"type":"virtualDimension","currency":"coins"},"delta":100},{"type":"ledger","id":"00000000-0000-4000-8000-000000000007","operation":"00000000-0000-4000-8000-000000000005","item":"00000000-0000-4000-8000-000000000001","revision":1,"session":null,"at":{"type":"event","utc":1768478400000,"day":"2026-01-15","zone":"Etc/UTC","offset":0},"dimension":{"type":"virtualDimension","currency":"gems"},"delta":2},{"type":"ledger","id":"00000000-0000-4000-8000-000000000008","operation":"00000000-0000-4000-8000-000000000005","item":"00000000-0000-4000-8000-000000000002","revision":1,"session":null,"at":{"type":"event","utc":1768478400000,"day":"2026-01-15","zone":"Etc/UTC","offset":0},"dimension":{"type":"timeDimension"},"delta":60000},{"type":"ledger","id":"00000000-0000-4000-8000-000000000009","operation":"00000000-0000-4000-8000-000000000005","item":"00000000-0000-4000-8000-000000000002","revision":1,"session":null,"at":{"type":"event","utc":1768478400000,"day":"2026-01-15","zone":"Etc/UTC","offset":0},"dimension":{"type":"budgetDimension","currency":"USD","digits":2},"delta":1000}],"achievements":[{"type":"achievement","id":"00000000-0000-4000-8000-000000000001","day":"2026-01-15","revision":1,"operation":"00000000-0000-4000-8000-000000000005","at":{"type":"event","utc":1768478400000,"day":"2026-01-15","zone":"Etc/UTC","offset":0},"bonus":{"type":"amounts","coins":10,"gems":0}}]}',1768478400000,'2026-01-15','Etc/UTC',0);
CREATE TABLE quest_accrual_remainders (
    quest_id TEXT NOT NULL REFERENCES items(id),
    currency TEXT NOT NULL CHECK (currency IN ('coins', 'gems')),
    remainder INTEGER NOT NULL CHECK (typeof(remainder) = 'integer' AND remainder BETWEEN 0 AND 3599999),
    PRIMARY KEY (quest_id, currency)
  );
INSERT INTO "quest_accrual_remainders" VALUES('00000000-0000-4000-8000-000000000001','coins',1234);
CREATE TABLE schema_version (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    version INTEGER NOT NULL CHECK (version >= 1)
  );
INSERT INTO "schema_version" VALUES(1,1);
CREATE TABLE sessions (
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
  );
INSERT INTO "sessions" VALUES('00000000-0000-4000-8000-000000000004',1,'00000000-0000-4000-8000-000000000001',1,'running','Etc/UTC','{"type":"clock","utc":1768478400000,"boot":"fixture-boot","monotonic":1000}','{"type":"clock","utc":1768478410000,"boot":"fixture-boot","monotonic":11000}',60000,10000,1768478460000,'00000000-0000-4000-8000-000000000104');
CREATE TABLE wallet_projection (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    revision INTEGER NOT NULL CHECK (typeof(revision) = 'integer' AND revision > 0),
    coins INTEGER NOT NULL CHECK (typeof(coins) = 'integer' AND coins >= 0),
    gems INTEGER NOT NULL CHECK (typeof(gems) = 'integer' AND gems >= 0)
  );
INSERT INTO "wallet_projection" VALUES(1,2,100,2);
CREATE UNIQUE INDEX one_active_session ON sessions ((1))
    WHERE status IN ('running', 'paused');
CREATE INDEX ledger_by_day ON ledger_entries(assigned_day, dimension, item_id);
CREATE INDEX ledger_by_operation ON ledger_entries(operation_id);
CREATE INDEX sessions_by_item ON sessions(item_id);
