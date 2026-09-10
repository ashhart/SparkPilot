//! Verify role-gated idempotent analyses survive intent lifetimes as leased operations and cancellation stops the upstream generation.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey;
use rand::RngCore;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_models::recipe::fixture::RecipeFixture;
use spark_telemetry::{InferenceSnapshot, MemoryPressure, SystemMonitor, SystemSnapshot};
use sparkd::auth;
use sparkd::clock::system_clock;
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::engine::EngineManager;
use sparkd::engine_backend::MockVllmBackend;
use sparkd::migration;
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};

const MODEL_ID: &str = "example/model-32b";
const PROFILE_ID: &str = "balanced-16k";

struct FixedMonitor;

impl SystemMonitor for FixedMonitor {
    fn system(&self) -> SystemSnapshot {
        SystemSnapshot {
            unified_memory_total_bytes: 240 << 30,
            unified_memory_available_bytes: 240 << 30,
            memory_pressure: MemoryPressure::Normal,
            cpu_utilisation: 0.10,
            load_average_1m: 0.5,
            disk_free_bytes: 100 << 30,
            temperature_celsius: Some(40.0),
            power_state: "normal".to_owned(),
            uptime_seconds: 100,
        }
    }

    fn inference(&self) -> InferenceSnapshot {
        InferenceSnapshot::default()
    }
}

struct Harness {
    state: AppState,
    backend: Arc<MockVllmBackend>,
    _dir: tempfile::TempDir,
}

struct Device {
    key: p256::ecdsa::SigningKey,
    id: uuid::Uuid,
}

fn fresh_device_key() -> p256::ecdsa::SigningKey {
    loop {
        let mut scalar = [0u8; 32];
        rand::rng().fill_bytes(&mut scalar);
        if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&scalar) {
            return key;
        }
    }
}

fn spki_der(key: &p256::ecdsa::SigningKey) -> Vec<u8> {
    key.verifying_key()
        .to_public_key_der()
        .expect("spki der")
        .as_bytes()
        .to_vec()
}

/// Use real signed HTTP with seeded owner/observer devices, migrations, installed recipe and mock engine to verify role enforcement.
async fn harness() -> (Harness, SocketAddr, Device, Device) {
    let dir = tempfile::tempdir().expect("tempdir");
    let mut identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("analysis-test")
        .expect("identity");
    identity.public.node_id = SIGNING_NODE_ID;

    let mut conn = rusqlite::Connection::open_in_memory().expect("db");
    migration::migrate(&mut conn).expect("migrate");

    let recipe = RecipeFixture::example();
    sparkd::store::upsert_catalogue_model(&conn, &recipe).expect("upsert catalogue model");
    sparkd::store::mark_model_installed(&conn, recipe.id(), 68_719_476_736)
        .expect("mark installed");

    let monitor: Arc<dyn SystemMonitor> = Arc::new(FixedMonitor);
    let database = Arc::new(parking_lot::Mutex::new(conn));
    let inventory = Arc::new(sparkd::models::ModelInventory {
        recipes: vec![recipe],
        allow_unverified_import: false,
    });

    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".to_owned(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "analysis-test".to_owned(),
        data_dir: dir.path().to_path_buf(),
        advertise: false,
        tls: false,
    };
    let state = AppState::new_with_clock(config, identity, monitor.clone(), None, system_clock())
        .with_models(inventory)
        .with_database(database.clone());

    let backend: Arc<MockVllmBackend> = Arc::new(MockVllmBackend::new());
    let manager = Arc::new(EngineManager::new(
        backend.clone(),
        state.jobs.clone(),
        state.events.clone(),
        state.identity.node_id().to_string(),
        monitor.clone(),
        database,
        dir.path().join("models"),
        Duration::from_millis(250),
        None,
    ));
    let state = state.with_engine(manager);

    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind");
    let addr = listener.local_addr().expect("addr");
    let served_state = state.clone();
    tokio::spawn(async move {
        axum::serve(listener, router(served_state))
            .await
            .expect("serve");
    });

    let owner = Device {
        key: fresh_device_key(),
        id: uuid::Uuid::new_v4(),
    };
    let observer = Device {
        key: fresh_device_key(),
        id: uuid::Uuid::new_v4(),
    };
    {
        let conn = state.database.as_ref().expect("db").lock();
        for (device, role) in [(&owner, "owner"), (&observer, "observer")] {
            sparkd::store::insert_device(
                &conn,
                &device.id,
                "analysis-test-device",
                "macos",
                &spki_der(&device.key),
                &format!("fp-analysis-{}", device.id),
                role,
            )
            .expect("seed device");
        }
    }

    (
        Harness {
            state,
            backend,
            _dir: dir,
        },
        addr,
        owner,
        observer,
    )
}

fn fresh_nonce() -> String {
    let mut nonce = [0u8; 24];
    rand::rng().fill_bytes(&mut nonce);
    base64url_encode(&nonce)
}

fn rfc3339_now() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .expect("rfc3339")
}

/// SPARK2 signed headers + body (§58.3).
async fn signed_json(
    client: &reqwest::Client,
    base: SocketAddr,
    device: &Device,
    method: &str,
    path: &str,
    body: Option<Value>,
    idempotency_key: Option<&str>,
) -> (reqwest::StatusCode, Value) {
    let body_bytes = body
        .map(|value| serde_json::to_vec(&value).expect("serialise body"))
        .unwrap_or_default();
    let timestamp = rfc3339_now();
    let nonce = fresh_nonce();
    let digest = sha256_hex(&body_bytes);
    let canonical = auth::canonical(
        method,
        path,
        &timestamp,
        &nonce,
        &digest,
        &device.id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = device.key.sign(canonical.as_bytes());

    let url = format!("http://{base}{path}");
    let mut builder = client
        .request(
            reqwest::Method::from_bytes(method.as_bytes()).expect("method"),
            &url,
        )
        .header("x-spark-device-id", device.id.to_string())
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header("x-spark-timestamp", timestamp)
        .header("x-spark-nonce", nonce)
        .header("x-spark-content-sha256", digest)
        .header("x-spark-signature", base64url_encode(&signature.to_bytes()));
    if !body_bytes.is_empty() {
        builder = builder.header("content-type", "application/json");
    }
    if let Some(key) = idempotency_key {
        builder = builder.header("idempotency-key", key);
    }
    let response = builder.body(body_bytes).send().await.expect("send");
    let status = response.status();
    let body: Value = response.json().await.unwrap_or(Value::Null);
    (status, body)
}

async fn post(
    client: &reqwest::Client,
    base: SocketAddr,
    device: &Device,
    path: &str,
    body: Value,
) -> (reqwest::StatusCode, Value) {
    signed_json(
        client,
        base,
        device,
        "POST",
        path,
        Some(body),
        Some(&uuid::Uuid::new_v4().to_string()),
    )
    .await
}

async fn get(
    client: &reqwest::Client,
    base: SocketAddr,
    device: &Device,
    path: &str,
) -> (reqwest::StatusCode, Value) {
    signed_json(client, base, device, "GET", path, None, None).await
}

/// Activate the fixture engine through ordinary preview/apply before submitting analyses.
async fn load_model(client: &reqwest::Client, base: SocketAddr, owner: &Device) {
    let (status, preview) = post(
        client,
        base,
        owner,
        "/api/v1/inference/load/preview",
        json!({ "model_id": MODEL_ID, "profile_id": PROFILE_ID }),
    )
    .await;
    assert_eq!(status, 200, "load preview: {preview}");
    let digest = preview["preview_digest"]
        .as_str()
        .expect("preview digest")
        .to_owned();

    let (status, operation) = post(
        client,
        base,
        owner,
        "/api/v1/inference/load",
        json!({
            "model_id": MODEL_ID,
            "profile_id": PROFILE_ID,
            "accepted_preview_digest": digest,
        }),
    )
    .await;
    assert_eq!(status, 202, "load: {operation}");
    let operation_id = operation["id"].as_str().expect("operation id").to_owned();
    let final_state = await_operation(client, base, owner, &operation_id).await;
    assert_eq!(final_state["state"], "succeeded", "load: {final_state}");
}

/// Poll an operation to a terminal state.
async fn await_operation(
    client: &reqwest::Client,
    base: SocketAddr,
    device: &Device,
    operation_id: &str,
) -> Value {
    for _ in 0..600 {
        let (status, body) = get(
            client,
            base,
            device,
            &format!("/api/v1/operations/{operation_id}"),
        )
        .await;
        assert_eq!(status, 200, "operation poll: {body}");
        let state = body["state"].as_str().unwrap_or_default().to_owned();
        if matches!(state.as_str(), "succeeded" | "failed" | "cancelled") {
            return body;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("operation {operation_id} never reached a terminal state");
}

fn analysis_body(text: &str) -> Value {
    json!({
        "instruction": "Summarise the attached document.",
        "text": text,
        "source_name": "quarterly-notes.txt",
        "max_output_tokens": 256,
    })
}

include!(
    "analysis_flow/scenarios/text_analysis_returns_a_durable_operation_carrying_the_result.rs"
);

include!("analysis_flow/scenarios/text_analysis_refuses_input_outside_the_documented_bounds.rs");

include!("analysis_flow/scenarios/text_analysis_refuses_unknown_request_fields.rs");

include!("analysis_flow/scenarios/one_idempotency_key_starts_exactly_one_analysis.rs");

include!("analysis_flow/scenarios/text_analysis_refuses_when_no_model_is_loaded.rs");

include!("analysis_flow/scenarios/text_analysis_refuses_a_target_that_is_not_this_runtime.rs");

include!("analysis_flow/scenarios/observers_cannot_start_a_text_analysis.rs");

include!("analysis_flow/scenarios/cancelling_a_text_analysis_stops_the_generation.rs");

include!("analysis_flow/scenarios/a_saturated_worker_pool_refuses_with_capacity_not_a_fault.rs");

include!("analysis_flow/scenarios/capabilities_publish_durable_text_analysis.rs");
