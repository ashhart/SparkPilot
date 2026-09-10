CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  owner_device_id TEXT NOT NULL,
  root_path TEXT NOT NULL UNIQUE,
  state TEXT NOT NULL CHECK (state IN ('creating','ready','stopped','failed','deleting')),
  repository_url TEXT,
  default_branch TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  policy_json TEXT NOT NULL DEFAULT '{}',
  metadata_json TEXT NOT NULL DEFAULT '{}',
  FOREIGN KEY (owner_device_id) REFERENCES devices(id)
);

CREATE TABLE IF NOT EXISTS project_members (
  project_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  permission TEXT NOT NULL CHECK (permission IN ('read','write','approve','admin')),
  granted_at TEXT NOT NULL,
  PRIMARY KEY (project_id, device_id),
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
  FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS project_worktrees (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  operation_id TEXT,
  path TEXT NOT NULL UNIQUE,
  base_commit TEXT NOT NULL,
  branch_name TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('creating','active','review','merged','rejected','failed','deleted')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
  FOREIGN KEY (operation_id) REFERENCES operations(id)
);

CREATE TABLE IF NOT EXISTS approvals (
  id TEXT PRIMARY KEY,
  operation_id TEXT NOT NULL,
  requested_by_device_id TEXT,
  requested_at TEXT NOT NULL,
  kind TEXT NOT NULL,
  resource_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending','approved','rejected','expired','cancelled')),
  decided_by_device_id TEXT,
  decided_at TEXT,
  decision_comment TEXT,
  expires_at TEXT,
  evidence_json TEXT NOT NULL DEFAULT '{}',
  FOREIGN KEY (operation_id) REFERENCES operations(id) ON DELETE CASCADE,
  FOREIGN KEY (requested_by_device_id) REFERENCES devices(id),
  FOREIGN KEY (decided_by_device_id) REFERENCES devices(id)
);

CREATE TABLE IF NOT EXISTS build_workers (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  device_id TEXT NOT NULL,
  platform_version TEXT NOT NULL,
  xcode_version TEXT NOT NULL,
  capabilities_json TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('online','busy','offline','revoked')),
  registered_at TEXT NOT NULL,
  last_seen_at TEXT,
  heartbeat_expires_at TEXT,
  FOREIGN KEY (device_id) REFERENCES devices(id)
);

CREATE TABLE IF NOT EXISTS builds (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  worker_id TEXT,
  commit_sha TEXT NOT NULL,
  scheme TEXT NOT NULL,
  configuration TEXT NOT NULL,
  destination TEXT NOT NULL,
  actions_json TEXT NOT NULL,
  timeout_seconds INTEGER NOT NULL,
  status TEXT NOT NULL
    CHECK (status IN ('queued','claimed','running','completed','failed','cancelled')),
  result_json TEXT NOT NULL DEFAULT '{}',
  requested_by_device_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  claim_token_hash BLOB,
  claim_expires_at TEXT,
  source_sha256 TEXT NOT NULL,
  requirements_json TEXT NOT NULL,
  claim_generation INTEGER NOT NULL DEFAULT 0,
  claim_request_id TEXT,
  recipe_json TEXT,
  recipe_sha256 TEXT,
  artifact_token_hash BLOB,
  FOREIGN KEY (project_id) REFERENCES projects(id),
  FOREIGN KEY (operation_id) REFERENCES operations(id),
  FOREIGN KEY (worker_id) REFERENCES build_workers(id),
  FOREIGN KEY (requested_by_device_id) REFERENCES devices(id)
);

CREATE TABLE IF NOT EXISTS build_artifacts (
  id TEXT PRIMARY KEY,
  operation_id TEXT NOT NULL,
  project_id TEXT NOT NULL,
  worker_id TEXT NOT NULL,
  build_id TEXT,
  claim_generation INTEGER NOT NULL DEFAULT 0,
  kind TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  FOREIGN KEY (operation_id) REFERENCES operations(id) ON DELETE CASCADE,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
  FOREIGN KEY (worker_id) REFERENCES build_workers(id),
  FOREIGN KEY (build_id) REFERENCES builds(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS builds_status_idx ON builds(status, created_at);
CREATE INDEX IF NOT EXISTS builds_project_idx ON builds(project_id, created_at DESC);
CREATE INDEX IF NOT EXISTS builds_worker_lease_idx
  ON builds(worker_id, status, claim_expires_at);
CREATE UNIQUE INDEX IF NOT EXISTS builds_worker_claim_request_idx
  ON builds(worker_id, claim_request_id)
  WHERE claim_request_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS build_artifacts_build_id_idx
  ON build_artifacts(build_id, claim_generation, id);


-- A stable checkout per project, independent of a client window or a live PTY.
CREATE TABLE IF NOT EXISTS development_workspaces (
    project_id TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
    worktree_id TEXT NOT NULL UNIQUE REFERENCES project_worktrees(id),
    image_digest TEXT NOT NULL,
    created_at TEXT NOT NULL
);
