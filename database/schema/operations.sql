CREATE TABLE IF NOT EXISTS operations (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  state TEXT NOT NULL CHECK (
    state IN ('requested','validating','queued','running','waiting_for_approval','cancelling','cancelled','succeeded','failed')
  ),
  actor_device_id TEXT NOT NULL,
  resource_id TEXT,
  progress REAL CHECK (progress IS NULL OR (progress >= 0 AND progress <= 1)),
  stage TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT,
  error_code TEXT,
  result_json TEXT,
  cancellable INTEGER NOT NULL,
  lease_owner TEXT,
  lease_expires_at TEXT,
  input_json TEXT NOT NULL DEFAULT '{}',
  FOREIGN KEY (actor_device_id) REFERENCES devices(id)
);

CREATE INDEX IF NOT EXISTS operations_state_idx ON operations(state, updated_at);
CREATE INDEX IF NOT EXISTS operations_actor_idx ON operations(actor_device_id, created_at DESC);
CREATE INDEX IF NOT EXISTS operations_resource_idx ON operations(resource_id, created_at DESC);

CREATE TABLE IF NOT EXISTS operation_stages (
  operation_id TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  stage TEXT NOT NULL,
  state TEXT NOT NULL,
  progress REAL,
  started_at TEXT NOT NULL,
  completed_at TEXT,
  details_json TEXT NOT NULL DEFAULT '{}',
  PRIMARY KEY (operation_id, sequence),
  FOREIGN KEY (operation_id) REFERENCES operations(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS events (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id TEXT NOT NULL UNIQUE,
  event_type TEXT NOT NULL,
  severity TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  node_id TEXT NOT NULL,
  cluster_id TEXT,
  operation_id TEXT,
  resource_id TEXT,
  visibility_json TEXT NOT NULL DEFAULT '{}',
  payload_json TEXT NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS events_type_idx ON events(event_type, sequence);
CREATE INDEX IF NOT EXISTS events_operation_idx ON events(operation_id, sequence);
CREATE INDEX IF NOT EXISTS events_time_idx ON events(occurred_at);

CREATE TABLE IF NOT EXISTS usage_daily (
  day TEXT NOT NULL,
  device_id TEXT NOT NULL,
  model_id TEXT NOT NULL,
  -- Normalize absent projects to '' because NULL keys defeat usage upsert deduplication.
  project_id TEXT NOT NULL DEFAULT '',
  prompt_tokens INTEGER NOT NULL DEFAULT 0,
  cached_prompt_tokens INTEGER NOT NULL DEFAULT 0,
  generated_tokens INTEGER NOT NULL DEFAULT 0,
  reasoning_tokens INTEGER NOT NULL DEFAULT 0,
  requests INTEGER NOT NULL DEFAULT 0,
  failures INTEGER NOT NULL DEFAULT 0,
  cumulative_ttft_ms INTEGER NOT NULL DEFAULT 0,
  cumulative_generation_ms INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, device_id, model_id, project_id),
  FOREIGN KEY (device_id) REFERENCES devices(id)
);

CREATE TABLE IF NOT EXISTS audit_records (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  occurred_at TEXT NOT NULL,
  actor_device_id TEXT,
  actor_role TEXT,
  source_route TEXT,
  action TEXT NOT NULL,
  resource TEXT,
  result TEXT NOT NULL,
  operation_id TEXT,
  request_id TEXT,
  details_json TEXT NOT NULL DEFAULT '{}',
  previous_hash BLOB,
  record_hash BLOB NOT NULL
);

CREATE INDEX IF NOT EXISTS audit_actor_idx ON audit_records(actor_device_id, sequence);
CREATE INDEX IF NOT EXISTS audit_action_idx ON audit_records(action, sequence);

CREATE TABLE IF NOT EXISTS remote_access (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  enabled INTEGER NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('disabled','private_overlay')),
  hostname TEXT,
  health TEXT NOT NULL,
  enabled_at TEXT,
  updated_at TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}'
);

