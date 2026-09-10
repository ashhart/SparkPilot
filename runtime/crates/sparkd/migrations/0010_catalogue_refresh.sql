CREATE TABLE IF NOT EXISTS catalogue_refresh_state (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  current_digest TEXT NOT NULL,
  signature_key_id TEXT NOT NULL,
  recipe_count INTEGER NOT NULL,
  previous_snapshot_available INTEGER NOT NULL DEFAULT 0,
  last_refreshed_at TEXT NOT NULL,
  last_operation_id TEXT
);
