-- Content-free fixed-target attempts; no prompt, output, credentials or routes.
CREATE TABLE inference_requests (
    attempt_id TEXT PRIMARY KEY,
    request_id TEXT NOT NULL,
    caller_device_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    model_id TEXT NOT NULL,
    profile_id TEXT,
    started_at INTEGER NOT NULL,
    finished_at INTEGER,
    outcome TEXT NOT NULL CHECK (outcome IN ('running','succeeded','failed','incomplete','cancelled_unconfirmed','interrupted_unknown')),
    failure_code TEXT,
    admission_ms REAL NOT NULL CHECK (admission_ms >= 0),
    first_frame_ms REAL,
    elapsed_ms REAL,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    provenance_json TEXT NOT NULL CHECK (length(provenance_json) <= 8192)
);
CREATE INDEX inference_requests_time ON inference_requests(started_at DESC, attempt_id);
CREATE INDEX inference_requests_caller ON inference_requests(caller_device_id, started_at DESC);
