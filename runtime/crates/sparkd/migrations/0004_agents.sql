-- Persist agent change state and an audit record for every tool call.

CREATE TABLE IF NOT EXISTS changes (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  worktree_branch TEXT NOT NULL,
  base_commit TEXT NOT NULL,
  task TEXT NOT NULL,
  status TEXT NOT NULL
    CHECK (status IN ('creating','planning','editing','review','approved','rejected','merged','failed')),
  diff_summary_json TEXT NOT NULL DEFAULT '{}',
  test_summary_json TEXT NOT NULL DEFAULT '{}',
  audit_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
  FOREIGN KEY (operation_id) REFERENCES operations(id)
);

CREATE TABLE IF NOT EXISTS agent_calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  change_id TEXT NOT NULL,
  tool TEXT NOT NULL,
  arguments_json TEXT NOT NULL DEFAULT '{}',
  outcome TEXT NOT NULL,
  at TEXT NOT NULL,
  FOREIGN KEY (change_id) REFERENCES changes(id) ON DELETE CASCADE
);
