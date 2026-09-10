CREATE TABLE IF NOT EXISTS consumed_remote_envelopes (
  envelope_sha256 TEXT PRIMARY KEY,
  consumed_at TEXT NOT NULL
);
