-- Numeric samples and closed pressure values prevent storing prompts, paths or addresses.

CREATE TABLE IF NOT EXISTS telemetry_samples (
  bucket_start INTEGER PRIMARY KEY,
  cpu_utilisation REAL,
  load_average_1m REAL,
  memory_total_bytes INTEGER,
  memory_available_bytes INTEGER,
  memory_pressure TEXT
    CHECK (memory_pressure IS NULL
           OR memory_pressure IN ('normal', 'warning', 'critical', 'emergency')),
  temperature_celsius REAL,
  accelerator_utilisation REAL,
  accelerator_memory_used_bytes INTEGER,
  accelerator_memory_total_bytes INTEGER,
  active_requests INTEGER,
  queue_depth INTEGER,
  tokens_per_second REAL,
  time_to_first_token_ms REAL
);

CREATE INDEX IF NOT EXISTS telemetry_samples_observed_idx
  ON telemetry_samples(bucket_start DESC);

-- Merge sums and counts associatively; zero counts preserve unavailable readings.
CREATE TABLE IF NOT EXISTS telemetry_minutes (
  bucket_start INTEGER PRIMARY KEY,
  sample_count INTEGER NOT NULL,
  cpu_utilisation_sum REAL NOT NULL DEFAULT 0,
  cpu_utilisation_n INTEGER NOT NULL DEFAULT 0,
  load_average_1m_sum REAL NOT NULL DEFAULT 0,
  load_average_1m_n INTEGER NOT NULL DEFAULT 0,
  memory_available_bytes_sum REAL NOT NULL DEFAULT 0,
  memory_available_bytes_n INTEGER NOT NULL DEFAULT 0,
  temperature_celsius_sum REAL NOT NULL DEFAULT 0,
  temperature_celsius_n INTEGER NOT NULL DEFAULT 0,
  accelerator_utilisation_sum REAL NOT NULL DEFAULT 0,
  accelerator_utilisation_n INTEGER NOT NULL DEFAULT 0,
  accelerator_memory_used_bytes_sum REAL NOT NULL DEFAULT 0,
  accelerator_memory_used_bytes_n INTEGER NOT NULL DEFAULT 0,
  active_requests_sum REAL NOT NULL DEFAULT 0,
  active_requests_n INTEGER NOT NULL DEFAULT 0,
  queue_depth_sum REAL NOT NULL DEFAULT 0,
  queue_depth_n INTEGER NOT NULL DEFAULT 0,
  tokens_per_second_sum REAL NOT NULL DEFAULT 0,
  tokens_per_second_n INTEGER NOT NULL DEFAULT 0,
  time_to_first_token_ms_sum REAL NOT NULL DEFAULT 0,
  time_to_first_token_ms_n INTEGER NOT NULL DEFAULT 0,
  memory_total_bytes_max INTEGER,
  accelerator_memory_total_bytes_max INTEGER,
  -- Ranks 0 normal, 1 warning, 2 critical and 3 emergency preserve the worst pressure on merge.
  memory_pressure_rank INTEGER
    CHECK (memory_pressure_rank IS NULL OR memory_pressure_rank BETWEEN 0 AND 3)
);

CREATE INDEX IF NOT EXISTS telemetry_minutes_observed_idx
  ON telemetry_minutes(bucket_start DESC);
