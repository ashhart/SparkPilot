//! Signed-route acceptance for node-owned independent-request placement.
use axum::{
    body::{Body, to_bytes},
    extract::ConnectInfo,
    http::{Request, StatusCode},
};
use p256::{ecdsa::signature::Signer, pkcs8::EncodePublicKey};
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_models::recipe::fixture::RecipeFixture;
use spark_telemetry::{InferenceSnapshot, MemoryPressure, SystemMonitor, SystemSnapshot};
use sparkd::{
    auth,
    clock::{ManualUtcClock, UtcClock},
    crypto::{base64url_encode, sha256_hex},
    engine::{EngineManager, EngineState},
    engine_backend::MockVllmBackend,
    migration,
    pool::PoolService,
    route::router,
    state::{AppState, RuntimeConfig},
};
use std::{net::SocketAddr, sync::Arc, time::Duration};
use tower::ServiceExt;
use uuid::Uuid;
const ROOT: &str = "/api/v1/inference";
const MODEL: &str = "example/model-32b";
struct Roomy;
impl SystemMonitor for Roomy {
    fn system(&self) -> SystemSnapshot {
        SystemSnapshot {
            unified_memory_total_bytes: 240 << 30,
            unified_memory_available_bytes: 200 << 30,
            memory_pressure: MemoryPressure::Normal,
            cpu_utilisation: 0.1,
            load_average_1m: 0.1,
            disk_free_bytes: 200 << 30,
            temperature_celsius: Some(40.0),
            power_state: "normal".into(),
            uptime_seconds: 100,
        }
    }
    fn inference(&self) -> InferenceSnapshot {
        InferenceSnapshot::default()
    }
}
struct Device {
    id: Uuid,
    key: p256::ecdsa::SigningKey,
    presence: p256::ecdsa::SigningKey,
}
fn device(state: &AppState, role: &str) -> Device {
    let key = p256::ecdsa::SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
    let presence = p256::ecdsa::SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
    let der = key.verifying_key().to_public_key_der().unwrap();
    let pder = presence.verifying_key().to_public_key_der().unwrap();
    let id = Uuid::new_v4();
    sparkd::store::insert_device_with_presence_key(
        &state.database.as_ref().unwrap().lock(),
        &id,
        role,
        "macos",
        der.as_bytes(),
        &sha256_hex(der.as_bytes()),
        role,
        Some((pder.as_bytes(), &sha256_hex(pder.as_bytes()))),
    )
    .unwrap();
    Device { id, key, presence }
}
struct Fixture {
    state: AppState,
    owner: Device,
    router: Device,
    other: Device,
    caller: Device,
    clock: Arc<ManualUtcClock>,
    backend: Arc<MockVllmBackend>,
    deployment: String,
    _dir: tempfile::TempDir,
}
async fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("pool-test")
        .unwrap();
    let mut conn = rusqlite::Connection::open(dir.path().join("state.sqlite")).unwrap();
    migration::migrate_with_recovery_point(&mut conn, &dir.path().join("state.sqlite")).unwrap();
    let mut recipe = RecipeFixture::example();
    recipe.profiles[0].max_sequences = 1;
    let signing = ed25519_dalek::SigningKey::from_bytes(&[9; 32]);
    recipe.signature.value = base64url_encode(
        &signing
            .sign(&recipe.canonical_without_signature().unwrap())
            .to_bytes(),
    );
    sparkd::store::upsert_catalogue_model(&conn, &recipe).unwrap();
    sparkd::store::mark_model_installed(&conn, recipe.id(), 1 << 30).unwrap();
    let database = Arc::new(parking_lot::Mutex::new(conn));
    let monitor: Arc<dyn SystemMonitor> = Arc::new(Roomy);
    let clock = Arc::new(ManualUtcClock::new(time::OffsetDateTime::now_utc()));
    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".into(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "pool-test".into(),
        data_dir: dir.path().into(),
        advertise: false,
        tls: false,
    };
    let mut state =
        AppState::new_with_clock(config, identity, monitor.clone(), None, clock.clone())
            .with_database(database.clone())
            .with_models(Arc::new(sparkd::models::ModelInventory {
                recipes: vec![recipe.clone()],
                allow_unverified_import: false,
            }))
            .with_disk_reserve(0);
    let owner = device(&state, "owner");
    let router_device = device(&state, "user");
    let other = device(&state, "developer");
    let caller = device(&state, "user");
    let backend = Arc::new(MockVllmBackend::new());
    backend.set_force_fallback_port(true);
    let manager = Arc::new(
        EngineManager::new(
            backend.clone(),
            state.jobs.clone(),
            state.events.clone(),
            state.identity.node_id().to_string(),
            monitor,
            database,
            dir.path().join("models"),
            Duration::from_millis(50),
            None,
        )
        .with_model_policy(0, Duration::from_secs(10), Duration::ZERO),
    );
    state = state.with_engine(manager.clone());
    let op = state
        .jobs
        .create(
            &state.database.as_ref().unwrap().lock(),
            "model.load",
            owner.id,
            Some(recipe.id()),
            "{}",
        )
        .unwrap();
    manager
        .spawn_load(op, &recipe, &recipe.profiles[0].id, false)
        .unwrap();
    tokio::time::timeout(Duration::from_secs(15), async {
        while manager.view().is_none_or(|v| v.state != EngineState::Ready) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("ready engine");
    let mut f = Fixture {
        state,
        owner,
        router: router_device,
        other,
        caller,
        clock,
        backend,
        deployment: String::new(),
        _dir: dir,
    };
    let (status, value) = send(
        &f,
        &f.owner,
        "GET",
        &format!("{ROOT}/node-capabilities"),
        None,
        None,
        false,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    f.deployment = value["deployments"][0]["deployment_id"]
        .as_str()
        .expect("eligible deployment")
        .into();
    f
}
fn request(
    f: &Fixture,
    device: &Device,
    method: &str,
    path: &str,
    value: Option<&Value>,
    key: Option<Uuid>,
    presence: bool,
) -> Request<Body> {
    let body = value
        .map(|v| serde_json::to_vec(v).unwrap())
        .unwrap_or_default();
    let nonce = base64url_encode(Uuid::new_v4().as_bytes());
    let timestamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let hash = sha256_hex(&body);
    let node = f.state.identity.node_id();
    let canonical = auth::canonical(method, path, &timestamp, &nonce, &hash, &device.id, &node);
    let signature: p256::ecdsa::Signature = device.key.sign(canonical.as_bytes());
    let mut req = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json")
        .header(auth::HEADER_DEVICE_ID, device.id.to_string())
        .header("x-spark-node-id", node.to_string())
        .header(auth::HEADER_TIMESTAMP, &timestamp)
        .header(auth::HEADER_NONCE, &nonce)
        .header(auth::HEADER_CONTENT_SHA256, &hash)
        .header(
            auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        );
    if let Some(key) = key {
        req = req.header("idempotency-key", key.to_string());
    }
    if presence {
        let expires_at = (f.clock.now() + time::Duration::seconds(45))
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap();
        let canonical = spark_contracts::user_presence_canonical(
            method,
            path,
            &timestamp,
            &nonce,
            &hash,
            &device.id,
            &expires_at,
            &node,
        );
        let signature: p256::ecdsa::Signature = device.presence.sign(canonical.as_bytes());
        let proof = spark_contracts::UserPresenceHeader {
            version: spark_contracts::USER_PRESENCE_PROOF_VERSION,
            expires_at,
            signature: base64url_encode(&signature.to_bytes()),
        };
        req = req.header(
            sparkd::user_presence::HEADER_USER_PRESENCE,
            base64url_encode(&serde_json::to_vec(&proof).unwrap()),
        );
    }
    let mut req = req.body(Body::from(body)).unwrap();
    req.extensions_mut().insert(ConnectInfo::<SocketAddr>(
        "127.0.0.1:49000".parse().unwrap(),
    ));
    req
}
async fn response(f: &Fixture, request: Request<Body>) -> (StatusCode, Value) {
    let response = router(f.state.clone()).oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 2 << 20).await.unwrap();
    (
        status,
        serde_json::from_slice(&bytes)
            .unwrap_or_else(|_| json!({"text":String::from_utf8_lossy(&bytes)})),
    )
}
async fn send(
    f: &Fixture,
    d: &Device,
    method: &str,
    path: &str,
    value: Option<&Value>,
    key: Option<Uuid>,
    presence: bool,
) -> (StatusCode, Value) {
    response(f, request(f, d, method, path, value, key, presence)).await
}
async fn post(
    f: &Fixture,
    d: &Device,
    path: &str,
    value: &Value,
    presence: bool,
) -> (StatusCode, Value) {
    send(
        f,
        d,
        "POST",
        path,
        Some(value),
        Some(Uuid::new_v4()),
        presence,
    )
    .await
}
fn policy(f: &Fixture, router: &Device) -> Value {
    json!({"pool_id":Uuid::new_v4(),"display_name":"Local chat","revision":1,"node_ids":[f.state.identity.node_id()],"caller_device_ids":[f.caller.id],"deployment_ids":[f.deployment],"router_device_ids":[router.id],"local_only":true,"paused":false,"max_concurrent_requests":1,"max_concurrent_per_caller":1,"max_queued_per_caller":8,"max_queued_requests":16,"max_buffered_bytes":1048576})
}
async fn configure(f: &Fixture, d: &Device) -> Value {
    configure_policy(f, d, policy(f, d)).await
}
async fn configure_policy(f: &Fixture, d: &Device, p: Value) -> Value {
    let (s, preview) = post(
        f,
        &f.owner,
        &format!("{ROOT}/pools/preview"),
        &json!({"expected_revision":0,"policy":p}),
        false,
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{preview}");
    let (s, v) = post(
        f,
        &f.owner,
        &format!("{ROOT}/pools/apply"),
        &json!({"preview_id":preview["preview_id"]}),
        true,
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let(s,grant)=post(f,&f.owner,&format!("{ROOT}/router-grants"),&json!({"pool_id":p["pool_id"],"policy_revision":1,"router_device_id":d.id,"caller_device_id":f.caller.id,"deployment_ids":[f.deployment],"actions":["reserve","execute","status","cancel"],"expires_in_seconds":3600}),true).await;
    assert_eq!(s, StatusCode::OK, "{grant}");
    grant
}
fn chat(stream: bool) -> Value {
    json!({"model":MODEL,"messages":[{"role":"user","content":"Unique private prompt must never enter persistent pool records"}],"stream":stream,"max_tokens":16})
}
fn reservation(f: &Fixture, grant: &Value, body: &Value) -> Value {
    let bytes = serde_json::to_vec(body).unwrap();
    json!({"grant_id":grant["grant_id"],"pool_id":grant["scope"]["pool_id"],"caller_device_id":f.caller.id,"request_id":Uuid::now_v7(),"attempt_id":Uuid::new_v4(),"deployment_id":f.deployment,"request_sha256":sha256_hex(&bytes),"request_bytes":bytes.len(),"policy_revision":1,"context_budget":4096,"output_budget":16,"lease_seconds":30,"required_capabilities":["text_chat","streaming"]})
}
async fn reserve(f: &Fixture, d: &Device, r: &Value) -> Value {
    let (s, v) = post(f, d, &format!("{ROOT}/reservations"), r, false).await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    v
}
fn path(r: &Value, action: &str) -> String {
    format!(
        "{ROOT}/reservations/{}{}",
        r["reservation_id"].as_str().unwrap(),
        action
    )
}
async fn close(f: Fixture) {
    tokio::task::spawn_blocking(move || drop(f)).await.unwrap();
}

include!("pool_admission_flow/scenarios/owner_presence_roles_and_exact_preview_receipts.rs");

include!("pool_admission_flow/scenarios/signed_audience_body_and_nonce_are_required.rs");

include!(
    "pool_admission_flow/scenarios/two_routers_and_direct_requests_share_the_final_engine_slot.rs"
);

include!(
    "pool_admission_flow/scenarios/grants_bind_router_caller_deployment_actions_and_expiry.rs"
);

include!(
    "pool_admission_flow/scenarios/reserve_replays_cannot_rebind_and_revocation_prevents_dispatch.rs"
);

include!(
    "pool_admission_flow/scenarios/expired_undispatched_leases_release_capacity_and_clock_rollback_fails_closed.rs"
);

include!(
    "pool_admission_flow/scenarios/restart_quarantines_accepted_work_and_never_duplicates_it.rs"
);

include!(
    "pool_admission_flow/scenarios/execute_has_exact_digest_terminal_receipt_and_no_persistent_content.rs"
);

include!("pool_admission_flow/scenarios/disconnected_router_does_not_release_inflight_capacity.rs");

include!(
    "pool_admission_flow/scenarios/pool_traffic_rejects_missing_peer_overlay_and_unsupported_options.rs"
);

include!(
    "pool_admission_flow/scenarios/unknown_capacity_is_released_only_by_confirmed_managed_stop.rs"
);

include!(
    "pool_admission_flow/scenarios/execute_connection_failure_returns_502_and_retains_quarantine.rs"
);

include!("pool_admission_flow/scenarios/direct_and_pool_admission_race_atomically_for_one_slot.rs");

include!(
    "pool_admission_flow/scenarios/retired_uuidv7_receipts_cannot_readmit_and_restart_rejects_clock_rollback.rs"
);

include!(
    "pool_admission_flow/scenarios/undispatched_cancel_allows_new_attempt_but_accepted_request_never_does.rs"
);

fn restarted_engine(f: &Fixture) -> Arc<EngineManager> {
    Arc::new(EngineManager::new(
        f.backend.clone(),
        f.state.jobs.clone(),
        f.state.events.clone(),
        f.state.identity.node_id().to_string(),
        Arc::new(Roomy),
        f.state.database.as_ref().unwrap().clone(),
        f.state.config.data_dir.join("models"),
        Duration::from_millis(50),
        None,
    ))
}
include!(
    "pool_admission_flow/scenarios/startup_stop_releases_only_the_persisted_managed_instance.rs"
);
include!(
    "pool_admission_flow/scenarios/losing_an_adoption_claim_is_not_proof_an_unknown_engine_stopped.rs"
);
include!("pool_admission_flow/scenarios/budgets_and_policy_revision_are_node_authoritative.rs");

include!(
    "pool_admission_flow/scenarios/startup_clock_rollback_keeps_management_available_and_pool_admission_closed.rs"
);
