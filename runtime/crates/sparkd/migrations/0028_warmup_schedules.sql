-- One-shot owner delegations, claimed before an engine side effect.
CREATE TABLE warmup_schedules (
    id TEXT PRIMARY KEY,
    node_id TEXT NOT NULL,
    owner_device_id TEXT NOT NULL REFERENCES devices(id),
    model_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    pin_json TEXT NOT NULL,
    due_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('pending','dispatching','running','succeeded','skipped','failed','disabled','revoked','expired','interrupted')),
    result_code TEXT NOT NULL,
    operation_id TEXT UNIQUE REFERENCES operations(id),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    CHECK (expires_at = due_at + 600)
);
CREATE INDEX warmup_schedules_due ON warmup_schedules(state, due_at);
