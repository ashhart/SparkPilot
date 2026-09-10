-- Service principals intentionally have no rows or privileges in devices.
CREATE TABLE pool_router_principals (
 principal_id TEXT PRIMARY KEY,
 kind TEXT NOT NULL CHECK(kind='pool_router'),
 router_node_id TEXT NOT NULL,
 request_public_key_spki BLOB NOT NULL,
 request_key_fingerprint TEXT NOT NULL UNIQUE,
 router_authority_fingerprint TEXT NOT NULL,
 enrolled_by_device_id TEXT NOT NULL REFERENCES devices(id),
 display_name TEXT NOT NULL,
 enrolled_at INTEGER NOT NULL,
 revoked INTEGER NOT NULL DEFAULT 0 CHECK(revoked IN (0,1))
);
CREATE UNIQUE INDEX pool_router_one_active_source ON pool_router_principals(router_node_id) WHERE revoked=0;
CREATE TABLE pool_router_enrollments (
 challenge_id TEXT PRIMARY KEY,
 actor_device_id TEXT NOT NULL REFERENCES devices(id),
 display_name TEXT NOT NULL,
 challenge_json TEXT NOT NULL,
 expires_at INTEGER NOT NULL,
 consumed INTEGER NOT NULL DEFAULT 0 CHECK(consumed IN (0,1))
);
CREATE TABLE pool_router_nonces (
 principal_id TEXT NOT NULL REFERENCES pool_router_principals(principal_id),
 nonce_hash BLOB NOT NULL,
 expires_at TEXT NOT NULL,
 PRIMARY KEY(principal_id,nonce_hash)
);
CREATE INDEX pool_router_nonce_expiry ON pool_router_nonces(expires_at);
CREATE TABLE pool_router_peers (
 node_id TEXT NOT NULL,
 principal_id TEXT NOT NULL,
 trust_json TEXT NOT NULL,
 authority_public_key TEXT NOT NULL,
 approved_by_device_id TEXT NOT NULL REFERENCES devices(id),
 approved_at INTEGER NOT NULL,
 PRIMARY KEY(node_id,principal_id)
);
