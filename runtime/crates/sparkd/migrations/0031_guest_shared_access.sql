-- A guest device is stored in devices with the lowest existing role; only a live grant here raises it to guest.
CREATE TABLE IF NOT EXISTS guest_grants (
  invitation_id TEXT PRIMARY KEY,
  device_id TEXT UNIQUE,
  display_name TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending','active','paused','revoked')),
  allowed_models_json TEXT NOT NULL DEFAULT '[]',
  allowed_hours_json TEXT NOT NULL,
  time_zone TEXT NOT NULL,
  max_concurrent_requests INTEGER NOT NULL,
  daily_token_budget INTEGER NOT NULL,
  expires_at INTEGER,
  created_by_device_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  joined_at TEXT,
  confirmed_at TEXT,
  revoked_at TEXT,
  FOREIGN KEY (invitation_id) REFERENCES pairing_invitations(id),
  FOREIGN KEY (device_id) REFERENCES devices(id),
  FOREIGN KEY (created_by_device_id) REFERENCES devices(id)
);

CREATE INDEX IF NOT EXISTS guest_grants_device_idx ON guest_grants(device_id, state);

-- Budget accounting is a security control, so it is written on the enforcement path and not with optional telemetry.
CREATE TABLE IF NOT EXISTS guest_usage (
  device_id TEXT NOT NULL,
  local_day TEXT NOT NULL,
  requests INTEGER NOT NULL DEFAULT 0,
  refusals INTEGER NOT NULL DEFAULT 0,
  prompt_tokens INTEGER NOT NULL DEFAULT 0,
  completion_tokens INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (device_id, local_day),
  FOREIGN KEY (device_id) REFERENCES devices(id)
);

CREATE INDEX IF NOT EXISTS guest_usage_day_idx ON guest_usage(local_day);

CREATE TABLE IF NOT EXISTS guest_refusals (
  device_id TEXT NOT NULL,
  local_day TEXT NOT NULL,
  reason_code TEXT NOT NULL,
  refusals INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, local_day, reason_code),
  FOREIGN KEY (device_id) REFERENCES devices(id)
);
