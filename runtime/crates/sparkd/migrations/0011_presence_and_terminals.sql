-- Single-use expiring presence nonces prove freshness and signing-key possession, not server-verifiable biometry.

CREATE TABLE IF NOT EXISTS presence_challenges (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  challenge BLOB NOT NULL,
  issued_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  consumed_at TEXT,
  FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS presence_challenges_expiry_idx
  ON presence_challenges(expires_at);

-- Bind terminal records to project and session identity plus their sandbox container.
CREATE TABLE IF NOT EXISTS project_terminals (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  creator_device_id TEXT NOT NULL,
  container_id TEXT NOT NULL,
  shell TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('running', 'closed')),
  created_at TEXT NOT NULL,
  closed_at TEXT,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
  FOREIGN KEY (creator_device_id) REFERENCES devices(id)
);

CREATE INDEX IF NOT EXISTS project_terminals_project_idx
  ON project_terminals(project_id, state);
