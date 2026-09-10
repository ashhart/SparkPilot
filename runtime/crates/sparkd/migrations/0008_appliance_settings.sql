-- Store operator preferences without Wi-Fi or travel-AP secrets, which remain write-only privileged inputs.

CREATE TABLE appliance_settings (
  setting_key TEXT PRIMARY KEY,
  value_json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  updated_by_device_id TEXT NOT NULL,
  FOREIGN KEY (updated_by_device_id) REFERENCES devices(id)
);

CREATE TABLE model_idle_policies (
  model_id TEXT NOT NULL,
  profile_id TEXT NOT NULL,
  idle_policy TEXT NOT NULL CHECK (
    idle_policy IN (
      'keep_ready',
      'unload_after_15m',
      'unload_after_30m',
      'unload_after_60m',
      'manual_only'
    )
  ),
  updated_at TEXT NOT NULL,
  updated_by_device_id TEXT NOT NULL,
  PRIMARY KEY (model_id, profile_id),
  FOREIGN KEY (updated_by_device_id) REFERENCES devices(id)
);
