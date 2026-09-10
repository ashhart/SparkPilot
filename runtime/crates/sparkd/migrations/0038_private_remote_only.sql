-- Retire public remote routes while preserving private routes and local device pairing.
CREATE TABLE remote_access_private (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  enabled INTEGER NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('disabled','private_overlay')),
  hostname TEXT,
  health TEXT NOT NULL,
  enabled_at TEXT,
  updated_at TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}'
);
INSERT INTO remote_access_private
  (singleton, enabled, mode, hostname, health, enabled_at, updated_at, metadata_json)
SELECT singleton,
  CASE WHEN mode = 'private_overlay' THEN enabled ELSE 0 END,
  CASE WHEN mode = 'private_overlay' THEN mode ELSE 'disabled' END,
  CASE WHEN mode = 'private_overlay' THEN hostname ELSE NULL END,
  CASE WHEN mode = 'private_overlay' THEN health ELSE 'disabled' END,
  CASE WHEN mode = 'private_overlay' THEN enabled_at ELSE NULL END,
  updated_at,
  CASE WHEN mode = 'private_overlay' THEN metadata_json ELSE '{}' END
FROM remote_access;
DROP TABLE remote_access;
ALTER TABLE remote_access_private RENAME TO remote_access;
DROP TABLE IF EXISTS consumed_remote_envelopes;
