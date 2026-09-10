-- Optional custom duration; legacy policy rows and their defaults remain intact.
CREATE TABLE model_idle_timeouts (
  model_id TEXT NOT NULL,
  profile_id TEXT NOT NULL,
  timeout_seconds INTEGER NOT NULL CHECK (timeout_seconds BETWEEN 60 AND 604800),
  PRIMARY KEY (model_id, profile_id),
  FOREIGN KEY (model_id, profile_id) REFERENCES model_idle_policies(model_id, profile_id) ON DELETE CASCADE
);
