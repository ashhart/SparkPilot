-- Require the claiming worker to present a short-lived secret whose digest binds its build result.

ALTER TABLE builds ADD COLUMN claim_token_hash BLOB;
ALTER TABLE builds ADD COLUMN claim_expires_at TEXT;

CREATE INDEX IF NOT EXISTS builds_status_idx ON builds(status, created_at);
CREATE INDEX IF NOT EXISTS builds_project_idx ON builds(project_id, created_at DESC);
