-- Record peer facts only from authenticated TLS identity or signed pairing invitations, with source provenance.

CREATE TABLE IF NOT EXISTS peer_facts (
  node_id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  authority_fingerprint TEXT NOT NULL,
  runtime_version TEXT NOT NULL,
  engine_image TEXT NOT NULL DEFAULT '',
  recorded_at TEXT NOT NULL,
  source TEXT NOT NULL
);
