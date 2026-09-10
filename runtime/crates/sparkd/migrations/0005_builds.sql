-- Keep build jobs on the Spark while workers claim queued work and report results.

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
  FOREIGN KEY (project_id) REFERENCES projects(id),
  FOREIGN KEY (operation_id) REFERENCES operations(id),
  FOREIGN KEY (worker_id) REFERENCES build_workers(id)
);
