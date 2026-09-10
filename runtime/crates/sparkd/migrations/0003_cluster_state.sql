-- Store cluster identity and lifecycle in one singleton, with membership retained in cluster_members.

CREATE TABLE IF NOT EXISTS cluster_state (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  state TEXT NOT NULL CHECK (
    state IN ('forming','validating','ready','degraded','failed')
  ),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
