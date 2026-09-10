-- A stable checkout per project, independent of a client window or a live PTY.
CREATE TABLE development_workspaces (
    project_id TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
    worktree_id TEXT NOT NULL UNIQUE REFERENCES project_worktrees(id),
    image_digest TEXT NOT NULL,
    created_at TEXT NOT NULL
);
