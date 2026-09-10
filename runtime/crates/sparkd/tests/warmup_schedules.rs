//! Full signed API plus deterministic daemon dispatch: no client timer or host Docker.
use axum::{
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use p256::{ecdsa::signature::Signer as _, pkcs8::EncodePublicKey};
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_models::{
    recipe::fixture::RecipeFixture,
    verify::{CatalogueRoot, testkit},
};
use spark_telemetry::{InferenceSnapshot, MemoryPressure, SystemMonitor, SystemSnapshot};
use sparkd::{
    auth,
    clock::{ManualUtcClock, UtcClock},
    crypto::{base64url_encode, sha256_hex},
    engine::EngineManager,
    engine_backend::MockVllmBackend,
    state::{AppState, RuntimeConfig},
};
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
use std::time::Duration;
use tower::ServiceExt as _;
use uuid::Uuid;
const MODEL: &str = "example/model-32b";
const PROFILE: &str = "balanced-16k";
const SEED: [u8; 32] = [29; 32];
struct Monitor(Arc<AtomicU64>);
impl SystemMonitor for Monitor {
    fn system(&self) -> SystemSnapshot {
        SystemSnapshot {
            unified_memory_total_bytes: 240 << 30,
            unified_memory_available_bytes: self.0.load(Ordering::Relaxed),
            memory_pressure: MemoryPressure::Normal,
            cpu_utilisation: 0.1,
            load_average_1m: 0.5,
            disk_free_bytes: 100 << 30,
            temperature_celsius: Some(40.0),
            power_state: "normal".into(),
            uptime_seconds: 100,
        }
    }
    fn inference(&self) -> InferenceSnapshot {
        InferenceSnapshot::default()
    }
}
struct Peer {
    state: AppState,
    clock: Arc<ManualUtcClock>,
    available: Arc<AtomicU64>,
    key: p256::ecdsa::SigningKey,
    presence: p256::ecdsa::SigningKey,
    device: Uuid,
    backend: Arc<MockVllmBackend>,
    _dir: tempfile::TempDir,
}
impl Drop for Peer {
    fn drop(&mut self) {
        // Drop MockVllmBackend's final blocking-runtime owner on an ordinary thread after async fixture teardown.
        let backend = self.backend.clone();
        let engine = self.state.engine.manager.take();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            drop(engine);
            drop(backend);
        });
    }
}

/// The environment production measures the fixture recipe in; a peak stored under any other is not evidence.
fn fixture_environment() -> String {
    sparkd::guard::recipe_environment(&RecipeFixture::example())
}

fn peer(role: &str) -> Peer {
    let dir = tempfile::tempdir().unwrap();
    let identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("warmup")
        .unwrap();
    let mut conn = rusqlite::Connection::open(dir.path().join("state.sqlite")).unwrap();
    sparkd::migration::migrate_with_recovery_point(&mut conn, &dir.path().join("state.sqlite"))
        .unwrap();
    let mut recipe = RecipeFixture::example();
    testkit::sign_recipe(&mut recipe, &ed25519_dalek::SigningKey::from_bytes(&SEED));
    sparkd::store::upsert_catalogue_model(&conn, &recipe).unwrap();
    sparkd::store::mark_model_installed(&conn, MODEL, 68_719_476_736).unwrap();
    let key = p256::ecdsa::SigningKey::from_slice(&[3; 32]).unwrap();
    let presence = p256::ecdsa::SigningKey::from_slice(&[4; 32]).unwrap();
    let device = Uuid::new_v4();
    let spki = key.verifying_key().to_public_key_der().unwrap();
    let pspki = presence.verifying_key().to_public_key_der().unwrap();
    sparkd::store::insert_device_with_presence_key(
        &conn,
        &device,
        "owner",
        "macos",
        spki.as_bytes(),
        &sha256_hex(spki.as_bytes()),
        role,
        Some((pspki.as_bytes(), &sha256_hex(pspki.as_bytes()))),
    )
    .unwrap();
    let clock = Arc::new(ManualUtcClock::new(time::OffsetDateTime::now_utc()));
    let available = Arc::new(AtomicU64::new(240 << 30));
    let monitor: Arc<dyn SystemMonitor> = Arc::new(Monitor(available.clone()));
    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".into(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "warmup".into(),
        data_dir: dir.path().into(),
        advertise: false,
        tls: false,
    };
    let state =
        AppState::new_with_clock(config, identity, monitor.clone(), Some(conn), clock.clone())
            .with_models(Arc::new(sparkd::models::ModelInventory {
                recipes: vec![recipe],
                allow_unverified_import: false,
            }));
    let database = state.database.as_ref().unwrap().clone();
    let cluster = Arc::new(sparkd::cluster::ClusterService::new(
        database.clone(),
        state.events.clone(),
        state.identity.node_id().to_string(),
        Arc::new(sparkd::cluster::NoLinkProbe),
        Arc::new(sparkd::cluster::NoCollectiveTest),
    ));
    let verifier = Arc::new(
        sparkd::catalogue_api::CatalogueRefreshService::new(
            dir.path().join("catalogue.json"),
            CatalogueRoot::from_seed(&SEED),
            state.models.as_ref().unwrap().clone(),
            database.clone(),
        )
        .unwrap(),
    );
    let backend = Arc::new(MockVllmBackend::new());
    let manager = Arc::new(
        EngineManager::new(
            backend.clone(),
            state.jobs.clone(),
            state.events.clone(),
            state.identity.node_id().to_string(),
            monitor,
            database,
            dir.path().join("models"),
            Duration::from_millis(10),
            None,
        )
        .with_model_policy(0, Duration::from_secs(2), Duration::ZERO),
    );
    Peer {
        state: state
            .with_engine(manager)
            .with_cluster(cluster)
            .with_catalogue_refresh(verifier),
        clock,
        available,
        key,
        presence,
        device,
        backend,
        _dir: dir,
    }
}
async fn call(
    peer: &Peer,
    method: &str,
    path: &str,
    body: Option<Value>,
    presence: bool,
    key: Uuid,
) -> (StatusCode, Value) {
    let raw = body
        .map(|body| serde_json::to_vec(&body).unwrap())
        .unwrap_or_default();
    let now = peer.clock.now();
    let timestamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let nonce = Uuid::new_v4().to_string();
    let digest = sha256_hex(&raw);
    let node = peer.state.identity.node_id();
    let canonical = auth::canonical(
        method,
        path,
        &timestamp,
        &nonce,
        &digest,
        &peer.device,
        &node,
    );
    let signature: p256::ecdsa::Signature = peer.key.sign(canonical.as_bytes());
    let mut request = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json")
        .header("idempotency-key", key.to_string())
        .header(auth::HEADER_DEVICE_ID, peer.device.to_string())
        .header(auth::HEADER_NODE_ID, node.to_string())
        .header(auth::HEADER_TIMESTAMP, &timestamp)
        .header(auth::HEADER_NONCE, &nonce)
        .header(auth::HEADER_CONTENT_SHA256, &digest)
        .header(
            auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        );
    if presence {
        let expires_at = (now + time::Duration::seconds(45))
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap();
        let canonical = spark_contracts::user_presence_canonical(
            method,
            path,
            &timestamp,
            &nonce,
            &digest,
            &peer.device,
            &expires_at,
            &node,
        );
        let signature: p256::ecdsa::Signature = peer.presence.sign(canonical.as_bytes());
        let proof = spark_contracts::UserPresenceHeader {
            version: spark_contracts::USER_PRESENCE_PROOF_VERSION,
            expires_at,
            signature: base64url_encode(&signature.to_bytes()),
        };
        request = request.header(
            "x-spark-user-presence",
            base64url_encode(&serde_json::to_vec(&proof).unwrap()),
        );
    }
    let response = sparkd::route::router(peer.state.clone())
        .oneshot(request.body(Body::from(raw)).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let body = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
    (status, serde_json::from_slice(&body).unwrap())
}
fn draft_request(peer: &Peer) -> Value {
    json!({"model_id":MODEL,"profile_id":PROFILE,"due_at":peer.clock.now().unix_timestamp()+600})
}
async fn reviewed(peer: &Peer) -> Value {
    let mut body = draft_request(peer);
    let (status, preview) = call(
        peer,
        "POST",
        "/api/v1/inference/warmups/preview",
        Some(body.clone()),
        false,
        Uuid::new_v4(),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{preview}");
    assert_eq!(preview["review"]["blockers"], json!([]), "{preview}");
    body["accepted_preview_digest"] = preview["review"]["preview_digest"].clone();
    body
}
async fn schedule(peer: &Peer) -> Value {
    let body = reviewed(peer).await;
    let (status, schedule) = call(
        peer,
        "POST",
        "/api/v1/inference/warmups",
        Some(body),
        true,
        Uuid::new_v4(),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{schedule}");
    schedule
}
async fn rows(peer: &Peer) -> Value {
    let (status, rows) = call(
        peer,
        "GET",
        "/api/v1/inference/warmups",
        None,
        false,
        Uuid::new_v4(),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{rows}");
    rows["items"].clone()
}

include!(
    "warmup_schedules/scenarios/warmup_signed_owner_presence_review_and_timing_are_required.rs"
);
include!("warmup_schedules/scenarios/warmup_review_binds_due_profile_and_idempotent_creation.rs");
include!("warmup_schedules/scenarios/warmup_due_memory_change_skips_and_never_retries.rs");
include!("warmup_schedules/scenarios/warmup_disabled_and_revoked_delegations_never_load.rs");
include!("warmup_schedules/scenarios/warmup_busy_review_is_conditional_but_due_never_replaces.rs");
include!("warmup_schedules/scenarios/warmup_pending_survives_restart_but_claim_is_not_replayed.rs");
include!("warmup_schedules/scenarios/warmup_count_cap_and_missed_window_are_bounded.rs");

include!("warmup_schedules/scenarios/warmup_unsafe_and_untrusted_profiles_cannot_be_delegated.rs");

include!("warmup_schedules/scenarios/warmup_measurement_changes_require_new_review.rs");

include!(
    "warmup_schedules/scenarios/warmup_disable_preserves_terminal_history_and_refuses_started_load.rs"
);

include!(
    "warmup_schedules/scenarios/warmup_unclaimed_persistence_and_uncertain_claim_restart_are_distinct.rs"
);

include!(
    "warmup_schedules/scenarios/warmup_review_at_one_minute_can_be_confirmed_after_owner_reads_it.rs"
);

include!(
    "warmup_schedules/scenarios/warmup_disable_rechecks_an_owner_authorized_before_demotion.rs"
);
