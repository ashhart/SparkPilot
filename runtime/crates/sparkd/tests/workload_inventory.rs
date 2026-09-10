//! Verify observation causes no lifecycle changes, ownership requires runtime records and inspection failures never claim empty hosts.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;

use axum::body::to_bytes;
use axum::http::{Method, Request, StatusCode};
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey as _;
use parking_lot::Mutex;
use rand::RngCore;
use rusqlite::Connection;
use serde_json::Value;
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_privd::backend::FakeBackend;
use spark_privd::workloads::{ObservedContainer, ObservedPort, ObservedWorkloads};
use sparkd::auth;
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::privd::PrivilegedClient;
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

struct TestClient {
    key: p256::ecdsa::SigningKey,
    device_id: uuid::Uuid,
}

/// Capture endpoint state and privileged requests for boundary assertions.
struct Harness {
    state: AppState,
    client: TestClient,
    observed_operations: Arc<std::sync::Mutex<Vec<String>>>,
    scripted_workloads: Arc<std::sync::Mutex<Option<ObservedWorkloads>>>,
}

fn signing_key() -> p256::ecdsa::SigningKey {
    loop {
        let mut scalar = [0; 32];
        rand::rng().fill_bytes(&mut scalar);
        if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&scalar) {
            return key;
        }
    }
}

/// Seed the exact engine id in durable records before expecting managed ownership.
const RECORDED_ENGINE_ID: &str = "2b0b0d1e-2b3f-4f7b-9b7a-1c1a4a4a9e11";

fn harness(role: &str, with_privileged_boundary: bool) -> Harness {
    let directory = tempfile::tempdir().unwrap();
    let mut identity = FileIdentityStore::new(directory.path().join("identity"))
        .load_or_create("test-node")
        .unwrap();
    identity.public.node_id = SIGNING_NODE_ID;
    let mut connection = Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut connection).unwrap();
    let client = TestClient {
        key: signing_key(),
        device_id: uuid::Uuid::new_v4(),
    };
    let signing_spki = client
        .key
        .verifying_key()
        .to_public_key_der()
        .unwrap()
        .as_bytes()
        .to_vec();
    sparkd::store::insert_device_with_presence_key(
        &connection,
        &client.device_id,
        "test client",
        "ios",
        &signing_spki,
        &sha256_hex(&signing_spki),
        role,
        None,
    )
    .unwrap();
    // Provide the required model/profile foreign-key target as a real engine record would.
    connection
        .execute(
            "INSERT INTO models (id, recipe_revision, recipe_digest, source_revision, \
             display_name, install_state) \
             VALUES ('example/model-32b', 'r1', 'sha256:aa', 'rev', 'Example', 'installed')",
            [],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO model_profiles (model_id, profile_id, context_length, max_sequences, \
             max_batched_tokens, gpu_memory_utilisation) \
             VALUES ('example/model-32b', 'balanced', 16384, 4, 8192, 0.7)",
            [],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO inference_instances (id, model_id, profile_id, node_id, state) \
             VALUES (?1, 'example/model-32b', 'balanced', ?2, 'stopped')",
            rusqlite::params![RECORDED_ENGINE_ID, identity.node_id().to_string()],
        )
        .unwrap();

    let database = Arc::new(Mutex::new(connection));
    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".into(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "test-node".into(),
        data_dir: directory.keep(),
        advertise: false,
        tls: false,
    };

    let backend = FakeBackend::default();
    let observed_operations = backend.observed_operations.clone();
    let scripted_workloads = backend.observed_workloads.clone();

    let mut state = AppState::new(
        config.clone(),
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        None,
    )
    .with_database(database);

    if with_privileged_boundary {
        let socket = config.data_dir.join("spark-privd.sock");
        let listener = spark_privd::server::bind_socket(&socket).unwrap();
        let allowed_uid = unsafe { libc::geteuid() };
        std::thread::spawn(move || {
            let _ = spark_privd::server::serve(listener, allowed_uid, &backend);
        });
        state = state.with_privileged_socket(PrivilegedClient::new(socket));
    }

    Harness {
        state,
        client,
        observed_operations,
        scripted_workloads,
    }
}

fn signed_get(client: &TestClient, path: &str) -> Request<axum::body::Body> {
    signed(client, Method::GET, path)
}

fn signed(client: &TestClient, method: Method, path: &str) -> Request<axum::body::Body> {
    let mut nonce = [0; 24];
    rand::rng().fill_bytes(&mut nonce);
    let nonce = base64url_encode(&nonce);
    let timestamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let content_sha256 = sha256_hex(&[]);
    let canonical = auth::canonical(
        method.as_str(),
        path,
        &timestamp,
        &nonce,
        &content_sha256,
        &client.device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = client.key.sign(canonical.as_bytes());
    Request::builder()
        .method(method)
        .uri(path)
        .header(auth::HEADER_DEVICE_ID, client.device_id.to_string())
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header(auth::HEADER_TIMESTAMP, &timestamp)
        .header(auth::HEADER_NONCE, &nonce)
        .header(auth::HEADER_CONTENT_SHA256, &content_sha256)
        .header(
            auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        )
        .body(axum::body::Body::empty())
        .unwrap()
}

async fn send(state: AppState, request: Request<axum::body::Body>) -> (StatusCode, Value) {
    let response = router(state).oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

fn container(id: &str, name: Option<&str>, image: Option<&str>) -> ObservedContainer {
    ObservedContainer {
        id: id.into(),
        name: name.map(str::to_owned),
        state: "running".into(),
        image: image.map(str::to_owned),
        ports: Vec::new(),
    }
}

/// Model a busy host with one runtime engine, one owner-started engine and one unidentifiable workload.
fn a_busy_host() -> ObservedWorkloads {
    let mut external = container(
        "1a3b",
        Some("deepseek-serve"),
        Some("lmsysorg/sglang:v0.4.1"),
    );
    external.ports.push(ObservedPort {
        host_ip: "0.0.0.0".into(),
        host_port: 30000,
        container_port: 30000,
        protocol: "tcp".into(),
    });
    ObservedWorkloads {
        containers: vec![
            container(
                "9f2c",
                Some(&format!("spark-model-{RECORDED_ENGINE_ID}")),
                Some("vllm/vllm-openai@sha256:aa"),
            ),
            external,
            container("7e5d", Some("legacy-batch-job"), Some("acme/private:1")),
        ],
        truncated: false,
        unreadable_lines: 0,
    }
}

fn workload_named<'a>(body: &'a Value, name: &str) -> &'a Value {
    body["workloads"]
        .as_array()
        .expect("workload list")
        .iter()
        .find(|workload| workload["name"] == name)
        .unwrap_or_else(|| panic!("no workload named {name} in {body}"))
}

include!(
    "workload_inventory/scenarios/managed_and_external_workloads_are_reported_as_different_states.rs"
);

include!("workload_inventory/scenarios/observing_a_workload_sends_it_no_lifecycle_command.rs");

include!("workload_inventory/scenarios/an_uninspectable_host_is_not_reported_as_an_idle_one.rs");

include!("workload_inventory/scenarios/a_runtime_without_a_privileged_boundary_says_so.rs");

include!(
    "workload_inventory/scenarios/adoption_capability_stays_off_when_its_signed_model_and_engine_links_are_absent.rs"
);

include!(
    "workload_inventory/scenarios/the_capability_document_reports_the_inventory_off_without_the_boundary.rs"
);

include!("workload_inventory/scenarios/host_detail_is_not_readable_by_every_paired_device.rs");

include!("workload_inventory/scenarios/the_inventory_needs_an_authenticated_device.rs");

include!("workload_inventory/scenarios/a_truncated_observation_is_reported_as_truncated.rs");

include!("workload_inventory/scenarios/the_response_matches_the_published_contract.rs");

async fn harness_unavailable_body() -> Value {
    let harness = harness("owner", false);
    let (_, body) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/workloads"),
    )
    .await;
    body
}

include!("workload_inventory/scenarios/no_response_field_can_carry_a_container_command_line.rs");

include!(
    "workload_inventory/scenarios/an_externally_named_container_cannot_pose_as_a_managed_one.rs"
);

include!("workload_inventory/scenarios/the_observation_is_a_get_and_needs_no_replay_key.rs");

include!(
    "workload_inventory/scenarios/a_container_runtime_this_build_cannot_read_is_not_reported_as_an_idle_host.rs"
);

include!("workload_inventory/scenarios/a_partly_unreadable_answer_is_reported_as_incomplete.rs");

include!("workload_inventory/scenarios/the_response_honours_the_contracts_workload_bound.rs");

include!("workload_inventory/scenarios/a_managed_engines_engine_word_comes_from_its_image.rs");

include!(
    "workload_inventory/scenarios/signed_telemetry_reads_an_existing_vllm_without_commanding_it.rs"
);

include!(
    "workload_inventory/scenarios/ordinary_devices_do_not_receive_external_workload_metrics.rs"
);
