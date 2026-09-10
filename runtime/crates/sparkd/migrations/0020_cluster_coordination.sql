-- Multi-member cluster authorisation and local transaction journal.

CREATE TABLE IF NOT EXISTS cluster_transactions (
  transaction_id TEXT PRIMARY KEY NOT NULL,
  cluster_id TEXT NOT NULL,
  proposal_digest TEXT NOT NULL CHECK(length(proposal_digest) = 64),
  coordinator_node_id TEXT NOT NULL,
  owner_device_id TEXT NOT NULL,
  local_address TEXT NOT NULL,
  peer_address TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('preparing','prepared','active','proved','collective','committing','committed','ready','rolling_back','rolled_back','failed')),
  proposal_json TEXT NOT NULL,
  grant_json TEXT NOT NULL,
  proof_json TEXT,
  fabric_auth_json TEXT,
  collective_json TEXT,
  commit_receipt_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(cluster_id),
  FOREIGN KEY(owner_device_id) REFERENCES devices(id)
);

CREATE TABLE IF NOT EXISTS cluster_link_proofs (
  cluster_id TEXT NOT NULL,
  member_node_id TEXT NOT NULL,
  peer_node_id TEXT NOT NULL,
  proposal_digest TEXT NOT NULL CHECK(length(proposal_digest) = 64),
  local_address TEXT NOT NULL,
  peer_address TEXT NOT NULL,
  interface TEXT NOT NULL,
  local_mac TEXT NOT NULL,
  neighbour_mac TEXT NOT NULL,
  speed_mbps INTEGER NOT NULL CHECK(speed_mbps >= 200000),
  mtu INTEGER NOT NULL CHECK(mtu = 9000),
  observed_at TEXT NOT NULL,
  authority_signature TEXT NOT NULL,
  PRIMARY KEY(cluster_id, member_node_id)
);

CREATE TABLE IF NOT EXISTS cluster_collective_proofs (
  cluster_id TEXT NOT NULL,
  member_node_id TEXT NOT NULL,
  proposal_digest TEXT NOT NULL CHECK(length(proposal_digest) = 64),
  node_rank INTEGER NOT NULL CHECK(node_rank IN (0, 1)),
  measured_latency_us INTEGER NOT NULL CHECK(measured_latency_us BETWEEN 0 AND 5000),
  measured_bandwidth_mbps INTEGER NOT NULL CHECK(measured_bandwidth_mbps >= 10000),
  operation_elapsed_ms INTEGER NOT NULL CHECK(operation_elapsed_ms BETWEEN 0 AND 190000),
  fabric_auth_json TEXT NOT NULL,
  observed_at TEXT NOT NULL,
  authority_signature TEXT NOT NULL,
  PRIMARY KEY(cluster_id, member_node_id),
  UNIQUE(cluster_id, node_rank)
);

CREATE TABLE IF NOT EXISTS cluster_device_grants (
  cluster_id TEXT NOT NULL,
  transaction_id TEXT NOT NULL,
  member_node_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('owner','administrator')),
  device_key_fingerprint TEXT NOT NULL CHECK(length(device_key_fingerprint) = 64),
  proposal_digest TEXT NOT NULL CHECK(length(proposal_digest) = 64),
  authority_signature TEXT NOT NULL,
  issued_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  PRIMARY KEY(cluster_id, member_node_id, device_id)
);

CREATE TABLE IF NOT EXISTS cluster_commit_receipts (
  cluster_id TEXT NOT NULL,
  transaction_id TEXT NOT NULL,
  member_node_id TEXT NOT NULL,
  proposal_digest TEXT NOT NULL CHECK(length(proposal_digest) = 64),
  committed_at TEXT NOT NULL,
  authority_signature TEXT NOT NULL,
  PRIMARY KEY(cluster_id, member_node_id)
);

CREATE TABLE IF NOT EXISTS cluster_launches (
  launch_id TEXT PRIMARY KEY NOT NULL,
  cluster_id TEXT NOT NULL,
  operation_id TEXT,
  recipe_id TEXT NOT NULL,
  profile_id TEXT NOT NULL,
  execution_spec_json TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('preparing','running','degraded','stopping','stopped','failed')),
  coordinator_node_id TEXT NOT NULL,
  worker_node_id TEXT NOT NULL,
  failure_code TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY(operation_id) REFERENCES operations(id)
);

CREATE INDEX IF NOT EXISTS cluster_transactions_state_idx
  ON cluster_transactions(state, updated_at);
CREATE INDEX IF NOT EXISTS cluster_launches_cluster_state_idx
  ON cluster_launches(cluster_id, state);
CREATE UNIQUE INDEX IF NOT EXISTS cluster_launches_one_active_per_cluster
  ON cluster_launches(cluster_id)
  WHERE state IN ('preparing','running','degraded','stopping');
