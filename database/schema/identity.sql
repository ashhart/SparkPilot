PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;

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
  presence_public_key_spki BLOB,
  presence_public_key_fingerprint TEXT,
  role TEXT NOT NULL CHECK (role IN ('owner','administrator','developer','user','observer')),
  capability_overrides_json TEXT NOT NULL DEFAULT '{}',
  paired_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS devices_role_idx ON devices(role, revoked_at);
CREATE UNIQUE INDEX IF NOT EXISTS devices_presence_key_idx
  ON devices(presence_public_key_fingerprint)
  WHERE presence_public_key_fingerprint IS NOT NULL;

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


CREATE INDEX IF NOT EXISTS pairing_challenges_expiry_idx ON pairing_challenges(expires_at);
CREATE INDEX IF NOT EXISTS idempotency_records_expiry_idx ON idempotency_records(expires_at);
