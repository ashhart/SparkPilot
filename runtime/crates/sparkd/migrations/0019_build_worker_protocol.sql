-- Outbound Mac build-worker leases and signed recipe/result bindings.

ALTER TABLE build_workers ADD COLUMN heartbeat_expires_at TEXT;

ALTER TABLE builds ADD COLUMN source_sha256 TEXT NOT NULL
  DEFAULT '0000000000000000000000000000000000000000000000000000000000000000';
ALTER TABLE builds ADD COLUMN requirements_json TEXT NOT NULL
  DEFAULT '{"platform":"macOS","architecture":"arm64","signing_required":false}';
ALTER TABLE builds ADD COLUMN claim_generation INTEGER NOT NULL DEFAULT 0;
ALTER TABLE builds ADD COLUMN claim_request_id TEXT;
ALTER TABLE builds ADD COLUMN recipe_json TEXT;
ALTER TABLE builds ADD COLUMN recipe_sha256 TEXT;
ALTER TABLE builds ADD COLUMN artifact_token_hash BLOB;

ALTER TABLE build_artifacts ADD COLUMN build_id TEXT;
ALTER TABLE build_artifacts ADD COLUMN claim_generation INTEGER NOT NULL DEFAULT 0;

-- Close legacy jobs lacking source digests and signed recipes so they cannot remain unclaimable queued operations.
UPDATE operations
   SET state = 'failed', stage = 'migration', progress = 1,
       completed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       error_code = 'BUILD_RECIPE_REQUIRES_RESUBMISSION'
 WHERE id IN (
       SELECT operation_id FROM builds
        WHERE status IN ('queued', 'claimed', 'running')
   );
UPDATE builds
   SET status = 'failed', worker_id = NULL, claim_token_hash = NULL,
       claim_expires_at = NULL,
       result_json = '{"migration_error":"BUILD_RECIPE_REQUIRES_RESUBMISSION"}',
       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE status IN ('queued', 'claimed', 'running');

-- Legacy artifact rows already carry the operation that produced them.
UPDATE build_artifacts
   SET build_id = (
       SELECT builds.id FROM builds
        WHERE builds.operation_id = build_artifacts.operation_id
   )
 WHERE build_id IS NULL;

CREATE INDEX IF NOT EXISTS builds_worker_lease_idx
  ON builds(worker_id, status, claim_expires_at);
CREATE UNIQUE INDEX IF NOT EXISTS builds_worker_claim_request_idx
  ON builds(worker_id, claim_request_id)
  WHERE claim_request_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS build_artifacts_build_id_idx
  ON build_artifacts(build_id, claim_generation, id);
