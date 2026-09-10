//! Require authenticated owner presence before queuing a validated typed hostname change.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;
use std::time::Duration;

use axum::body::to_bytes;
use axum::http::{Method, Request, StatusCode};
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey as _;
use parking_lot::Mutex;
use rand::RngCore;
use rusqlite::Connection;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_privd::backend::FakeBackend;
use sparkd::auth;
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::privd::PrivilegedClient;
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

struct TestClient {
    key: p256::ecdsa::SigningKey,
    presence_key: p256::ecdsa::SigningKey,
    device_id: uuid::Uuid,
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

fn test_state(
    role: &str,
) -> (
    AppState,
    TestClient,
    Arc<std::sync::Mutex<Vec<String>>>,
    tempfile::TempDir,
) {
    let directory = tempfile::tempdir().unwrap();
    let mut identity = FileIdentityStore::new(directory.path().join("identity"))
        .load_or_create("test-node")
        .unwrap();
    identity.public.node_id = SIGNING_NODE_ID;
    let mut connection = Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut connection).unwrap();
    let client = TestClient {
        key: signing_key(),
        presence_key: signing_key(),
        device_id: uuid::Uuid::new_v4(),
    };
    let signing_spki = client
        .key
        .verifying_key()
        .to_public_key_der()
        .unwrap()
        .as_bytes()
        .to_vec();
    let presence_spki = client
        .presence_key
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
        Some((&presence_spki, &sha256_hex(&presence_spki))),
    )
    .unwrap();

    let database = Arc::new(Mutex::new(connection));
    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".into(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "test-node".into(),
        data_dir: directory.path().to_path_buf(),
        advertise: false,
        tls: false,
    };
    let socket = directory.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    let backend = FakeBackend::default();
    let observed = backend.observed_operations.clone();
    let allowed_uid = unsafe { libc::geteuid() };
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, allowed_uid, &backend);
    });
    let state = AppState::new(
        config,
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        None,
    )
    .with_database(database)
    .with_privileged_socket(PrivilegedClient::new(socket));
    (state, client, observed, directory)
}

fn signed_hostname_request(
    client: &TestClient,
    idempotency_key: uuid::Uuid,
    hostname: &str,
    include_presence: bool,
) -> Request<axum::body::Body> {
    let path = "/api/v1/system/hostname";
    let body = serde_json::to_vec(&json!({ "hostname": hostname })).unwrap();
    let mut nonce = [0; 24];
    rand::rng().fill_bytes(&mut nonce);
    let nonce = base64url_encode(&nonce);
    let now = time::OffsetDateTime::now_utc();
    let timestamp = now
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let content_sha256 = sha256_hex(&body);
    let canonical = auth::canonical(
        "POST",
        path,
        &timestamp,
        &nonce,
        &content_sha256,
        &client.device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = client.key.sign(canonical.as_bytes());
    let mut builder = Request::builder()
        .method(Method::POST)
        .uri(path)
        .header("content-type", "application/json")
        .header("idempotency-key", idempotency_key.to_string())
        .header(auth::HEADER_DEVICE_ID, client.device_id.to_string())
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
            .unwrap();
        let canonical = spark_contracts::user_presence_canonical(
            "POST",
            path,
            &timestamp,
            &nonce,
            &content_sha256,
            &client.device_id,
            &expires_at,
            &SIGNING_NODE_ID,
        );
        let signature: p256::ecdsa::Signature = client.presence_key.sign(canonical.as_bytes());
        let proof = spark_contracts::UserPresenceHeader {
            version: spark_contracts::USER_PRESENCE_PROOF_VERSION,
            expires_at,
            signature: base64url_encode(&signature.to_bytes()),
        };
        builder = builder.header(
            sparkd::user_presence::HEADER_USER_PRESENCE,
            base64url_encode(&serde_json::to_vec(&proof).unwrap()),
        );
    }
    builder.body(axum::body::Body::from(body)).unwrap()
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

fn wait_for_hostname(observed: &Arc<std::sync::Mutex<Vec<String>>>) {
    for _ in 0..80 {
        if observed
            .lock()
            .unwrap()
            .iter()
            .any(|kind| kind == "set_hostname")
        {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("timed out waiting for hostname change");
}

#[tokio::test]
async fn owner_can_set_one_validated_hostname_with_presence_and_replay() {
    let (state, client, observed, _directory) = test_state("owner");
    let key = uuid::Uuid::new_v4();
    let (status, operation) = send(
        state.clone(),
        signed_hostname_request(&client, key, "spark1", true),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(operation["kind"], "system.hostname");
    assert_eq!(operation["cancellable"], false);

    let (retry_status, retry) =
        send(state, signed_hostname_request(&client, key, "spark1", true)).await;
    assert_eq!(retry_status, StatusCode::ACCEPTED);
    assert_eq!(retry["id"], operation["id"]);
    wait_for_hostname(&observed);
    assert_eq!(
        observed
            .lock()
            .unwrap()
            .iter()
            .filter(|kind| kind.as_str() == "set_hostname")
            .count(),
        1
    );
}

#[tokio::test]
async fn invalid_missing_presence_and_non_owner_requests_never_reach_privd() {
    let (owner_state, owner, owner_observed, _directory) = test_state("owner");
    let (invalid_status, invalid) = send(
        owner_state.clone(),
        signed_hostname_request(&owner, uuid::Uuid::new_v4(), "Spark.local", true),
    )
    .await;
    assert_eq!(invalid_status, StatusCode::BAD_REQUEST);
    assert_eq!(invalid["error"]["code"], "INVALID_HOSTNAME");

    let (presence_status, presence) = send(
        owner_state,
        signed_hostname_request(&owner, uuid::Uuid::new_v4(), "spark1", false),
    )
    .await;
    assert_eq!(presence_status, StatusCode::FORBIDDEN);
    assert_eq!(presence["error"]["code"], "USER_PRESENCE_REQUIRED");
    assert!(owner_observed.lock().unwrap().is_empty());

    let (admin_state, admin, admin_observed, _directory) = test_state("administrator");
    let (role_status, role) = send(
        admin_state,
        signed_hostname_request(&admin, uuid::Uuid::new_v4(), "spark1", true),
    )
    .await;
    assert_eq!(role_status, StatusCode::FORBIDDEN);
    assert_eq!(role["error"]["code"], "ROLE_FORBIDDEN");
    assert!(admin_observed.lock().unwrap().is_empty());
}
