-- Count failed join-code attempts node-wide so distributed sources cannot bypass the per-IP brute-force limit.
CREATE TABLE IF NOT EXISTS join_code_attempts (
  attempted_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS join_code_attempts_time_idx
  ON join_code_attempts(attempted_at);
