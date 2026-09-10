-- Recurring work the Spark performs on its own clock, and the durable record of every run.
CREATE TABLE IF NOT EXISTS automations (
    id TEXT PRIMARY KEY,
    node_id TEXT NOT NULL,
    owner_device_id TEXT NOT NULL REFERENCES devices(id),
    name TEXT NOT NULL,
    instructions TEXT NOT NULL,
    schedule_preset TEXT NOT NULL CHECK (
        schedule_preset IN ('daily', 'weekdays', 'every_n_hours', 'weekly', 'custom')
    ),
    schedule_expression TEXT NOT NULL,
    timezone TEXT NOT NULL,
    model_id TEXT NOT NULL,
    profile_id TEXT,
    web_access INTEGER NOT NULL CHECK (web_access IN (0, 1)),
    notify INTEGER NOT NULL CHECK (notify IN (0, 1)),
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    next_run_at INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS automations_due ON automations(enabled, next_run_at);

CREATE TABLE IF NOT EXISTS automation_runs (
    id TEXT PRIMARY KEY,
    automation_id TEXT NOT NULL REFERENCES automations(id) ON DELETE CASCADE,
    operation_id TEXT UNIQUE REFERENCES operations(id),
    state TEXT NOT NULL CHECK (
        state IN ('running', 'succeeded', 'failed', 'skipped', 'interrupted')
    ),
    trigger TEXT NOT NULL CHECK (trigger IN ('schedule', 'manual')),
    scheduled_for INTEGER,
    started_at INTEGER NOT NULL,
    finished_at INTEGER,
    result_text TEXT,
    error_code TEXT,
    tool_calls_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS automation_runs_recent ON automation_runs(automation_id, started_at DESC);
-- One run per automation per slot, enforced by storage rather than by timing.
CREATE UNIQUE INDEX IF NOT EXISTS automation_runs_slot
    ON automation_runs(automation_id, scheduled_for)
    WHERE scheduled_for IS NOT NULL;
