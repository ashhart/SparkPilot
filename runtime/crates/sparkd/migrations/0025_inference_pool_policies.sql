-- Independent-request pools never alter distributed-model cluster membership.
CREATE TABLE inference_pool_policies (
    pool_id TEXT PRIMARY KEY,
    revision INTEGER NOT NULL CHECK (revision > 0),
    policy_json TEXT NOT NULL,
    owner_device_id TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE TABLE inference_pool_previews (
    preview_id TEXT PRIMARY KEY,
    pool_id TEXT NOT NULL,
    actor_device_id TEXT NOT NULL,
    expected_revision INTEGER NOT NULL,
    policy_json TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    consumed INTEGER NOT NULL DEFAULT 0 CHECK (consumed IN (0,1))
);
CREATE TABLE inference_router_grants (
    grant_id TEXT PRIMARY KEY,
    pool_id TEXT NOT NULL REFERENCES inference_pool_policies(pool_id),
    grant_json TEXT NOT NULL,
    revoked INTEGER NOT NULL DEFAULT 0 CHECK (revoked IN (0,1)),
    expires_at INTEGER NOT NULL
);
CREATE TABLE inference_pool_mutations (
    actor_device_id TEXT NOT NULL,
    path TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    body_sha256 TEXT NOT NULL,
    response_json TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (actor_device_id, path, idempotency_key)
);
