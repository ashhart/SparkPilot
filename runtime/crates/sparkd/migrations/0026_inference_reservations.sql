CREATE TABLE inference_reservations (
    reservation_id TEXT PRIMARY KEY,
    request_id TEXT NOT NULL,
    request_created_at_milliseconds INTEGER NOT NULL,
    attempt_id TEXT NOT NULL UNIQUE,
    grant_id TEXT NOT NULL REFERENCES inference_router_grants(grant_id),
    pool_id TEXT NOT NULL REFERENCES inference_pool_policies(pool_id),
    router_device_id TEXT NOT NULL,
    caller_device_id TEXT NOT NULL,
    deployment_id TEXT NOT NULL,
    engine_instance_id TEXT NOT NULL,
    capacity_released INTEGER NOT NULL DEFAULT 0 CHECK(capacity_released IN (0,1)),
    request_sha256 TEXT NOT NULL,
    request_bytes INTEGER NOT NULL CHECK(request_bytes>0 AND request_bytes<=1048576),
    binding_sha256 TEXT NOT NULL,
    policy_revision INTEGER NOT NULL,
    context_budget INTEGER NOT NULL,
    output_budget INTEGER NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('reserved','accepted','cancel_requested','outcome_unknown','succeeded','failed','cancelled','expired')),
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    reason TEXT
);
CREATE UNIQUE INDEX inference_request_once ON inference_reservations(caller_device_id,request_id) WHERE NOT (state IN ('cancelled','expired') AND reason='not_dispatched');
CREATE TABLE inference_pool_clock (
    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
    observed_at_milliseconds INTEGER NOT NULL
);
