CREATE TABLE IF NOT EXISTS optional_services (
  service_id TEXT PRIMARY KEY,
  enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
  pending_install INTEGER NOT NULL DEFAULT 0 CHECK (pending_install IN (0, 1)),
  gateway_token_sha256 TEXT NOT NULL CHECK (length(gateway_token_sha256) = 64),
  owner_device_id TEXT NOT NULL,
  recipe_revision TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (owner_device_id) REFERENCES devices(id)
);
