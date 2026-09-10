-- Authenticated fabric evidence is read-only and grants no runtime ownership of external clusters or workloads.

CREATE TABLE IF NOT EXISTS fabric_peer_proofs (
  observer_node_id TEXT NOT NULL,
  observer_port_id TEXT NOT NULL,
  peer_node_id TEXT NOT NULL,
  peer_port_id TEXT,
  verified_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('mutual_tls_challenge')),
  PRIMARY KEY (observer_node_id, observer_port_id, peer_node_id),
  FOREIGN KEY (observer_node_id) REFERENCES peer_facts(node_id) ON DELETE CASCADE,
  FOREIGN KEY (peer_node_id) REFERENCES peer_facts(node_id) ON DELETE CASCADE,
  CHECK (observer_node_id <> peer_node_id),
  CHECK (length(observer_port_id) BETWEEN 1 AND 128),
  CHECK (peer_port_id IS NULL OR length(peer_port_id) BETWEEN 1 AND 128)
);

CREATE INDEX IF NOT EXISTS fabric_peer_proofs_peer_idx
  ON fabric_peer_proofs(peer_node_id, expires_at);
