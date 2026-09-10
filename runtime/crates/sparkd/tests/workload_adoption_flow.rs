const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use axum::body::to_bytes;
use axum::http::{Method, Request, StatusCode};
use axum::routing::get;
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey as _;
use rand::RngCore;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_models::recipe::fixture::RecipeFixture;
use spark_privd::adoption::AdoptionInspection;
use spark_privd::backend::FakeBackend;
use sparkd::auth;
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::engine::EngineManager;
use sparkd::engine_backend::MockVllmBackend;
use sparkd::migration;
use sparkd::models::ModelInventory;
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

const MODEL: &str = "example/model-32b";
const PROFILE: &str = "balanced-16k";

struct Peer {
    state: AppState,
    device_key: p256::ecdsa::SigningKey,
    presence_key: p256::ecdsa::SigningKey,
    device_id: uuid::Uuid,
    workload_id: String,
    inspection: Arc<std::sync::Mutex<Option<AdoptionInspection>>>,
    privileged_operations: Arc<std::sync::Mutex<Vec<String>>>,
    _directory: tempfile::TempDir,
}

fn signing_key() -> p256::ecdsa::SigningKey {
    loop {
        let mut scalar = [0_u8; 32];
        rand::rng().fill_bytes(&mut scalar);
        if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&scalar) {
            return key;
        }
    }
}

fn spki(key: &p256::ecdsa::SigningKey) -> Vec<u8> {
    key.verifying_key()
        .to_public_key_der()
        .expect("SPKI")
        .as_bytes()
        .to_vec()
}

async fn model_service(served_name: String) -> SocketAddr {
    let app = axum::Router::new()
        .route("/health", get(|| async { StatusCode::OK }))
        .route(
            "/v1/models",
            get(move || {
                let served_name = served_name.clone();
                async move { axum::Json(json!({ "data": [{ "id": served_name }] })) }
            }),
        );
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
        .await
        .expect("bind model service");
    let address = listener.local_addr().expect("model service address");
    tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .expect("serve model service")
    });
    address
}

async fn peer(role: &str) -> Peer {
    let directory = tempfile::tempdir().expect("tempdir");
    let mut identity = FileIdentityStore::new(directory.path().join("identity"))
        .load_or_create("adoption-test")
        .expect("identity");
    identity.public.node_id = SIGNING_NODE_ID;
    let recipe = RecipeFixture::example();
    let served_name = recipe.engine.served_name.clone();
    let model_address = model_service(served_name).await;

    let mut connection = rusqlite::Connection::open_in_memory().expect("database");
    migration::migrate(&mut connection).expect("migrations");
    sparkd::store::upsert_catalogue_model(&connection, &recipe).expect("catalogue model");
    sparkd::store::mark_model_installed(&connection, recipe.id(), 1024).expect("installed model");
    let database = Arc::new(parking_lot::Mutex::new(connection));
    let inventory = Arc::new(ModelInventory {
        recipes: vec![recipe],
        allow_unverified_import: false,
    });

    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".into(),
        listen: "127.0.0.1:0".parse().expect("listen"),
        node_name: "adoption-test".into(),
        data_dir: directory.path().into(),
        advertise: false,
        tls: false,
    };
    let monitor: Arc<dyn spark_telemetry::SystemMonitor> =
        Arc::new(spark_telemetry::FakeSystemMonitor);
    let mut state = AppState::new(config, identity, monitor.clone(), None)
        .with_database(database.clone())
        .with_models(inventory);

    let workload_id = "a".repeat(64);
    let inspection = AdoptionInspection {
        eligible: true,
        evidence_digest: "b".repeat(64),
        workload_id: workload_id.clone(),
        host_port: Some(model_address.port()),
        mismatch_codes: Vec::new(),
    };
    let privileged = FakeBackend::default();
    *privileged
        .adoption_inspection
        .lock()
        .expect("adoption inspection") = Some(inspection);
    let scripted_inspection = privileged.adoption_inspection.clone();
    let privileged_operations = privileged.observed_operations.clone();
    let socket = directory.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).expect("privileged socket");
    let allowed_uid = unsafe { libc::geteuid() };
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, allowed_uid, &privileged);
    });
    state = state.with_privileged_socket(sparkd::privd::PrivilegedClient::new(socket));

    let backend = Arc::new(MockVllmBackend::new());
    let engine = Arc::new(EngineManager::new(
        backend,
        state.jobs.clone(),
        state.events.clone(),
        state.identity.node_id().to_string(),
        monitor,
        database,
        directory.path().join("models"),
        Duration::from_millis(50),
        None,
    ));
    state = state.with_engine(engine);

    let device_key = signing_key();
    let presence_key = signing_key();
    let device_id = uuid::Uuid::new_v4();
    let device_spki = spki(&device_key);
    let presence_spki = spki(&presence_key);
    sparkd::store::insert_device_with_presence_key(
        &state.database.as_ref().expect("database").lock(),
        &device_id,
        "adoption client",
        "ios",
        &device_spki,
        &sha256_hex(&device_spki),
        role,
        Some((&presence_spki, &sha256_hex(&presence_spki))),
    )
    .expect("device");

    Peer {
        state,
        device_key,
        presence_key,
        device_id,
        workload_id,
        inspection: scripted_inspection,
        privileged_operations,
        _directory: directory,
    }
}

fn signed_request(
    peer: &Peer,
    path: &str,
    body: &Value,
    idempotency_key: uuid::Uuid,
    include_presence: bool,
) -> Request<axum::body::Body> {
    let body = serde_json::to_vec(body).expect("body");
    let mut nonce = [0_u8; 24];
    rand::rng().fill_bytes(&mut nonce);
    let nonce = base64url_encode(&nonce);
    let now = time::OffsetDateTime::now_utc();
    let timestamp = now
        .format(&time::format_description::well_known::Rfc3339)
        .expect("timestamp");
    let content_sha256 = sha256_hex(&body);
    let canonical = auth::canonical(
        "POST",
        path,
        &timestamp,
        &nonce,
        &content_sha256,
        &peer.device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = peer.device_key.sign(canonical.as_bytes());
    let mut request = Request::builder()
        .method(Method::POST)
        .uri(path)
        .header("content-type", "application/json")
        .header("idempotency-key", idempotency_key.to_string())
        .header(auth::HEADER_DEVICE_ID, peer.device_id.to_string())
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header(auth::HEADER_TIMESTAMP, &timestamp)
        .header(auth::HEADER_NONCE, &nonce)
        .header(auth::HEADER_CONTENT_SHA256, &content_sha256)
        .header(
            auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        );
    if include_presence {
        let expires_at = (now + time::Duration::seconds(45))
            .format(&time::format_description::well_known::Rfc3339)
            .expect("presence expiry");
        let canonical = spark_contracts::user_presence_canonical(
            "POST",
            path,
            &timestamp,
            &nonce,
            &content_sha256,
            &peer.device_id,
            &expires_at,
            &SIGNING_NODE_ID,
        );
        let signature: p256::ecdsa::Signature = peer.presence_key.sign(canonical.as_bytes());
        let proof = spark_contracts::UserPresenceHeader {
            version: spark_contracts::USER_PRESENCE_PROOF_VERSION,
            expires_at,
            signature: base64url_encode(&signature.to_bytes()),
        };
        request = request.header(
            sparkd::user_presence::HEADER_USER_PRESENCE,
            base64url_encode(&serde_json::to_vec(&proof).expect("presence proof")),
        );
    }
    request.body(axum::body::Body::from(body)).expect("request")
}

async fn send(peer: &Peer, request: Request<axum::body::Body>) -> (StatusCode, Value) {
    let response = router(peer.state.clone())
        .oneshot(request)
        .await
        .expect("route");
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("response body");
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn drop_peer(peer: Peer) {
    tokio::task::spawn_blocking(move || drop(peer))
        .await
        .expect("drop test runtime");
}

fn preview_path(peer: &Peer) -> String {
    format!("/api/v1/workloads/{}/adoption/preview", peer.workload_id)
}

fn adopt_path(peer: &Peer) -> String {
    format!("/api/v1/workloads/{}/adopt", peer.workload_id)
}

async fn issue_adoption_preview(peer: &Peer) -> Value {
    let path = preview_path(peer);
    let (status, body) = send(
        peer,
        signed_request(
            peer,
            &path,
            &json!({ "model_id": MODEL, "profile_id": PROFILE }),
            uuid::Uuid::new_v4(),
            false,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["blockers"], json!([]));
    assert!(body["warnings"].as_array().is_some_and(|warnings| {
        warnings.iter().any(|warning| {
            warning["code"] == "CONTROL_TRANSFER"
                && warning["owner_explanation"]
                    .as_str()
                    .is_some_and(|copy| copy.contains("may stop this exact container"))
        })
    }));
    body
}

async fn wait_terminal(peer: &Peer, operation_id: uuid::Uuid) -> Value {
    for _ in 0..100 {
        let row = {
            let connection = peer.state.database.as_ref().expect("database").lock();
            peer.state
                .jobs
                .get(&connection, operation_id)
                .expect("operation read")
                .expect("operation")
        };
        if matches!(row.state.as_str(), "succeeded" | "failed" | "cancelled") {
            return serde_json::to_value(row).expect("operation JSON");
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("operation did not finish");
}

#[tokio::test]
async fn exact_adoption_requires_presence_replays_once_and_relinquishes_without_stopping() {
    let peer = peer("owner").await;
    let preview = issue_adoption_preview(&peer).await;
    let path = adopt_path(&peer);
    let key = uuid::Uuid::new_v4();
    let apply = json!({
        "model_id": MODEL,
        "profile_id": PROFILE,
        "accepted_preview_digest": preview["preview_digest"],
    });

    let (status, body) = send(&peer, signed_request(&peer, &path, &apply, key, false)).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["error"]["code"], "USER_PRESENCE_REQUIRED");

    let first = send(&peer, signed_request(&peer, &path, &apply, key, true));
    let second = send(&peer, signed_request(&peer, &path, &apply, key, true));
    let ((first_status, first_body), (second_status, second_body)) = tokio::join!(first, second);
    assert_eq!(first_status, StatusCode::ACCEPTED, "{first_body}");
    assert_eq!(second_status, StatusCode::ACCEPTED, "{second_body}");
    assert_eq!(first_body["id"], second_body["id"]);
    let operation_id = first_body["id"]
        .as_str()
        .expect("operation id")
        .parse()
        .expect("operation UUID");
    assert_eq!(
        wait_terminal(&peer, operation_id).await["state"],
        "succeeded"
    );
    let rows: i64 = peer
        .state
        .database
        .as_ref()
        .expect("database")
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM inference_instances WHERE container_id = ?1 AND json_extract(metadata_json, '$.ownership_origin') = 'external_adoption'",
            [&peer.workload_id],
            |row| row.get(0),
        )
        .expect("ownership row");
    assert_eq!(rows, 1);

    let preview_path = format!("/api/v1/workloads/{}/relinquish/preview", peer.workload_id);
    let (status, relinquish_preview) = send(
        &peer,
        signed_request(
            &peer,
            &preview_path,
            &json!({}),
            uuid::Uuid::new_v4(),
            false,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{relinquish_preview}");
    let relinquish_path = format!("/api/v1/workloads/{}/relinquish", peer.workload_id);
    let (status, relinquished) = send(
        &peer,
        signed_request(
            &peer,
            &relinquish_path,
            &json!({ "accepted_preview_digest": relinquish_preview["preview_digest"] }),
            uuid::Uuid::new_v4(),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{relinquished}");
    assert_eq!(relinquished["container_changed"], false);
    assert!(
        !peer
            .privileged_operations
            .lock()
            .expect("privileged operations")
            .iter()
            .any(|operation| operation == "stop_adopted_model")
    );
    drop_peer(peer).await;
}

#[tokio::test]
async fn changed_inspection_evidence_makes_the_server_preview_stale() {
    let peer = peer("administrator").await;
    let preview = issue_adoption_preview(&peer).await;
    peer.inspection
        .lock()
        .expect("inspection")
        .as_mut()
        .expect("scripted inspection")
        .evidence_digest = "c".repeat(64);
    let path = adopt_path(&peer);
    let (status, body) = send(
        &peer,
        signed_request(
            &peer,
            &path,
            &json!({
                "model_id": MODEL,
                "profile_id": PROFILE,
                "accepted_preview_digest": preview["preview_digest"],
            }),
            uuid::Uuid::new_v4(),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert_eq!(body["error"]["code"], "PREVIEW_STALE");
    assert!(
        peer.state
            .engine
            .manager
            .as_ref()
            .expect("engine")
            .view()
            .is_none()
    );
    drop_peer(peer).await;
}

#[tokio::test]
async fn a_user_cannot_even_issue_an_adoption_review() {
    let peer = peer("user").await;
    let path = preview_path(&peer);
    let (status, body) = send(
        &peer,
        signed_request(
            &peer,
            &path,
            &json!({ "model_id": MODEL, "profile_id": PROFILE }),
            uuid::Uuid::new_v4(),
            false,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["error"]["code"], "ROLE_FORBIDDEN");
    drop_peer(peer).await;
}
