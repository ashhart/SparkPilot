-- Bootstrap schema; the migration runner applies connection-level PRAGMAs separately.

CREATE TABLE IF NOT EXISTS schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS runtime_identity (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  node_id TEXT NOT NULL UNIQUE,
  node_name TEXT NOT NULL,
  cluster_id TEXT,
  node_role TEXT NOT NULL CHECK (node_role IN ('standalone','leader','worker')),
  authority_public_key BLOB NOT NULL,
  authority_fingerprint TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  platform TEXT NOT NULL CHECK (platform IN ('ios','ipados','macos')),
  public_key_spki BLOB NOT NULL,
  public_key_fingerprint TEXT NOT NULL UNIQUE,
  role TEXT NOT NULL CHECK (role IN ('owner','administrator','developer','user','observer')),
  capability_overrides_json TEXT NOT NULL DEFAULT '{}',
  paired_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS devices_role_idx ON devices(role, revoked_at);

CREATE TABLE IF NOT EXISTS pairing_invitations (
  id TEXT PRIMARY KEY,
  role TEXT NOT NULL,
  nonce_hash BLOB NOT NULL UNIQUE,
  issued_by_device_id TEXT NOT NULL,
  device_name_hint TEXT,
  issued_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  consumed_at TEXT,
  consumed_by_device_id TEXT,
  revoked_at TEXT,
  signed_payload_json TEXT NOT NULL,
  FOREIGN KEY (issued_by_device_id) REFERENCES devices(id),
  FOREIGN KEY (consumed_by_device_id) REFERENCES devices(id)
);

CREATE INDEX IF NOT EXISTS pairing_invites_expiry_idx
  ON pairing_invitations(expires_at, consumed_at, revoked_at);

CREATE TABLE IF NOT EXISTS pairing_challenges (
  id TEXT PRIMARY KEY,
  invitation_id TEXT NOT NULL,
  challenge_hash BLOB NOT NULL UNIQUE,
  device_public_key_fingerprint TEXT NOT NULL,
  issued_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  consumed_at TEXT,
  FOREIGN KEY (invitation_id) REFERENCES pairing_invitations(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS request_nonces (
  device_id TEXT NOT NULL,
  nonce_hash BLOB NOT NULL,
  seen_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  PRIMARY KEY (device_id, nonce_hash),
  FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS request_nonces_expiry_idx ON request_nonces(expires_at);

CREATE TABLE IF NOT EXISTS idempotency_records (
  device_id TEXT NOT NULL,
  method TEXT NOT NULL,
  path TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  body_hash TEXT NOT NULL,
  status_code INTEGER NOT NULL,
  response_json TEXT,
  operation_id TEXT,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  PRIMARY KEY (device_id, method, path, idempotency_key),
  FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idempotency_expiry_idx ON idempotency_records(expires_at);

CREATE TABLE IF NOT EXISTS provider_credentials (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  display_name TEXT NOT NULL,
  secret_reference TEXT NOT NULL,
  created_by_device_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_used_at TEXT,
  revoked_at TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  FOREIGN KEY (created_by_device_id) REFERENCES devices(id)
);

CREATE TABLE IF NOT EXISTS models (
  id TEXT PRIMARY KEY,
  recipe_revision TEXT NOT NULL,
  recipe_digest TEXT NOT NULL,
  source_revision TEXT NOT NULL,
  display_name TEXT NOT NULL,
  install_state TEXT NOT NULL CHECK (
    install_state IN ('available','downloading','verifying','installed','failed','incompatible','unverified')
  ),
  installed_at TEXT,
  manifest_path TEXT,
  total_bytes INTEGER,
  measured_peak_bytes INTEGER,
  last_used_at TEXT,
  failure_code TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS model_files (
  model_id TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  sha256 TEXT NOT NULL,
  download_state TEXT NOT NULL,
  completed_bytes INTEGER NOT NULL DEFAULT 0,
  etag TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (model_id, relative_path),
  FOREIGN KEY (model_id) REFERENCES models(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS model_profiles (
  model_id TEXT NOT NULL,
  profile_id TEXT NOT NULL,
  context_length INTEGER NOT NULL,
  max_sequences INTEGER NOT NULL,
  max_batched_tokens INTEGER NOT NULL,
  gpu_memory_utilisation REAL NOT NULL,
  expected_peak_bytes INTEGER,
  measured_peak_bytes INTEGER,
  safe INTEGER NOT NULL DEFAULT 1,
  last_failure_code TEXT,
  last_measured_at TEXT,
  PRIMARY KEY (model_id, profile_id),
  FOREIGN KEY (model_id) REFERENCES models(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS inference_instances (
  id TEXT PRIMARY KEY,
  model_id TEXT NOT NULL,
  profile_id TEXT NOT NULL,
  node_id TEXT NOT NULL,
  cluster_id TEXT,
  state TEXT NOT NULL CHECK (
    state IN ('loading','ready','idle','draining','unloading','failed','stopped')
  ),
  container_id TEXT,
  internal_port INTEGER,
  internal_secret_reference TEXT,
  started_at TEXT,
  ready_at TEXT,
  stopped_at TEXT,
  failure_code TEXT,
  peak_memory_bytes INTEGER,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  FOREIGN KEY (model_id, profile_id) REFERENCES model_profiles(model_id, profile_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS inference_active_per_node_idx
  ON inference_instances(node_id)
  WHERE state IN ('loading','ready','idle','draining','unloading');

CREATE TABLE IF NOT EXISTS operations (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  state TEXT NOT NULL CHECK (
    state IN ('requested','validating','queued','running','waiting_for_approval','cancelling','cancelled','succeeded','failed')
  ),
  actor_device_id TEXT NOT NULL,
  resource_id TEXT,
  progress REAL CHECK (progress IS NULL OR (progress >= 0 AND progress <= 1)),
  stage TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT,
  error_code TEXT,
  result_json TEXT,
  cancellable INTEGER NOT NULL,
  lease_owner TEXT,
  lease_expires_at TEXT,
  input_json TEXT NOT NULL DEFAULT '{}',
  FOREIGN KEY (actor_device_id) REFERENCES devices(id)
);

CREATE INDEX IF NOT EXISTS operations_state_idx ON operations(state, updated_at);
CREATE INDEX IF NOT EXISTS operations_actor_idx ON operations(actor_device_id, created_at DESC);
CREATE INDEX IF NOT EXISTS operations_resource_idx ON operations(resource_id, created_at DESC);

CREATE TABLE IF NOT EXISTS operation_stages (
  operation_id TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  stage TEXT NOT NULL,
  state TEXT NOT NULL,
  progress REAL,
  started_at TEXT NOT NULL,
  completed_at TEXT,
  details_json TEXT NOT NULL DEFAULT '{}',
  PRIMARY KEY (operation_id, sequence),
  FOREIGN KEY (operation_id) REFERENCES operations(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS events (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id TEXT NOT NULL UNIQUE,
  event_type TEXT NOT NULL,
  severity TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  node_id TEXT NOT NULL,
  cluster_id TEXT,
  operation_id TEXT,
  resource_id TEXT,
  visibility_json TEXT NOT NULL DEFAULT '{}',
  payload_json TEXT NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS events_type_idx ON events(event_type, sequence);
CREATE INDEX IF NOT EXISTS events_operation_idx ON events(operation_id, sequence);
CREATE INDEX IF NOT EXISTS events_time_idx ON events(occurred_at);

CREATE TABLE IF NOT EXISTS usage_daily (
  day TEXT NOT NULL,
  device_id TEXT NOT NULL,
  model_id TEXT NOT NULL,
  project_id TEXT,
  prompt_tokens INTEGER NOT NULL DEFAULT 0,
  cached_prompt_tokens INTEGER NOT NULL DEFAULT 0,
  generated_tokens INTEGER NOT NULL DEFAULT 0,
  reasoning_tokens INTEGER NOT NULL DEFAULT 0,
  requests INTEGER NOT NULL DEFAULT 0,
  failures INTEGER NOT NULL DEFAULT 0,
  cumulative_ttft_ms INTEGER NOT NULL DEFAULT 0,
  cumulative_generation_ms INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, device_id, model_id, project_id),
  FOREIGN KEY (device_id) REFERENCES devices(id)
);

CREATE TABLE IF NOT EXISTS audit_records (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  occurred_at TEXT NOT NULL,
  actor_device_id TEXT,
  actor_role TEXT,
  source_route TEXT,
  action TEXT NOT NULL,
  resource TEXT,
  result TEXT NOT NULL,
  operation_id TEXT,
  request_id TEXT,
  details_json TEXT NOT NULL DEFAULT '{}',
  previous_hash BLOB,
  record_hash BLOB NOT NULL
);

CREATE INDEX IF NOT EXISTS audit_actor_idx ON audit_records(actor_device_id, sequence);
CREATE INDEX IF NOT EXISTS audit_action_idx ON audit_records(action, sequence);

CREATE TABLE IF NOT EXISTS remote_access (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  enabled INTEGER NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('disabled','cloudflare_public','private_overlay')),
  hostname TEXT,
  tunnel_id TEXT,
  tunnel_secret_reference TEXT,
  access_audience TEXT,
  health TEXT NOT NULL,
  enabled_at TEXT,
  updated_at TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS cluster_members (
  cluster_id TEXT NOT NULL,
  node_id TEXT NOT NULL,
  name TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('leader','worker')),
  authority_fingerprint TEXT NOT NULL,
  endpoint TEXT,
  reachable INTEGER NOT NULL DEFAULT 0,
  qsfp_interface TEXT,
  qsfp_health TEXT,
  runtime_version TEXT,
  last_seen_at TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  PRIMARY KEY (cluster_id, node_id)
);

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
  FOREIGN KEY (device_id) REFERENCES devices(id)
);

CREATE TABLE IF NOT EXISTS build_artifacts (
  id TEXT PRIMARY KEY,
  operation_id TEXT NOT NULL,
  project_id TEXT NOT NULL,
  worker_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  FOREIGN KEY (operation_id) REFERENCES operations(id) ON DELETE CASCADE,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
  FOREIGN KEY (worker_id) REFERENCES build_workers(id)
);

CREATE TRIGGER IF NOT EXISTS devices_owner_guard
BEFORE UPDATE OF role, revoked_at ON devices
WHEN OLD.role = 'owner'
BEGIN
  SELECT CASE
    WHEN (
      SELECT COUNT(*) FROM devices
      WHERE role = 'owner'
        AND revoked_at IS NULL
        AND id <> OLD.id
    ) = 0
    THEN RAISE(ABORT, 'cannot remove last active owner')
  END;
END;
