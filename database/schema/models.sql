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
  measured_environment TEXT,
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

