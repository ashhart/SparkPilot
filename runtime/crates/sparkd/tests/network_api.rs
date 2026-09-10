//! Verify read-only network status and elevated configuration without inventing unavailable interface evidence.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;

use axum::body::to_bytes;
use axum::http::{Method, Request, StatusCode};
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey;
use parking_lot::Mutex;
use rand::RngCore;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::network::{NetworkConfigurator, NetworkService, UnavailableInterfaces};
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

struct TestClient {
    key: p256::ecdsa::SigningKey,
    device_id: uuid::Uuid,
}

fn random_signing_key() -> p256::ecdsa::SigningKey {
    loop {
        let mut scalar = [0u8; 32];
        rand::rng().fill_bytes(&mut scalar);
        if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&scalar) {
            return key;
        }
    }
}

struct RecordingConfigurator;

impl NetworkConfigurator for RecordingConfigurator {
    fn configure_direct(&self, enabled: bool) -> Result<Value, String> {
        Ok(json!({ "profile": "spark-direct", "enabled": enabled }))
    }

    fn configure_travel_ap(
        &self,
        _configuration_id: uuid::Uuid,
        enabled: bool,
        ssid: Option<&str>,
        passphrase: Option<&str>,
    ) -> Result<Value, String> {
        let _ = passphrase;
        Ok(json!({
            "profile": "spark-travel-ap",
            "enabled": enabled,
            "ssid": ssid.unwrap_or("Spark-A7F2"),
            "passphrase": "generated-passphrase",
        }))
    }
}

fn test_state(role: &'static str) -> (AppState, TestClient, tempfile::TempDir) {
    let directory = tempfile::tempdir().unwrap();
    let mut identity = FileIdentityStore::new(directory.path().join("identity"))
        .load_or_create("network-node")
        .unwrap();
    identity.public.node_id = SIGNING_NODE_ID;
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut connection).unwrap();

    let client = TestClient {
        key: random_signing_key(),
        device_id: uuid::Uuid::new_v4(),
    };
    let spki = client
        .key
        .verifying_key()
        .to_public_key_der()
        .unwrap()
        .as_bytes()
        .to_vec();
    sparkd::store::insert_device(
        &connection,
        &client.device_id,
        "network test",
        "macos",
        &spki,
        &sha256_hex(&spki),
        role,
    )
    .unwrap();

    let database = Arc::new(Mutex::new(connection));
    let configurator = Arc::new(RecordingConfigurator);
    let state = AppState::new(
        RuntimeConfig {
            api_major: 1,
            runtime_version: "0.1.0".to_owned(),
            listen: "127.0.0.1:0".parse().unwrap(),
            node_name: "network-node".to_owned(),
            data_dir: directory.path().to_path_buf(),
            advertise: false,
            tls: false,
        },
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        None,
    )
    .with_database(database.clone())
    .with_network(Arc::new(NetworkService::new(
        Arc::new(UnavailableInterfaces),
        configurator,
    )));
    (state, client, directory)
}

fn signed_request(
    _state: &AppState,
    client: &TestClient,
    method: &str,
    path: &str,
    body: Option<&Value>,
    extra: Vec<(&'static str, String)>,
) -> Request<axum::body::Body> {
    let body_bytes = body
        .map(|value| serde_json::to_vec(value).unwrap())
        .unwrap_or_default();
    let mut nonce = [0u8; 24];
    rand::rng().fill_bytes(&mut nonce);
    let timestamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let content_sha256 = sha256_hex(&body_bytes);
    let canonical = sparkd::auth::canonical(
        method,
        path,
        &timestamp,
        &base64url_encode(&nonce),
        &content_sha256,
        &client.device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = client.key.sign(canonical.as_bytes());
    let builder = Request::builder()
        .method(Method::from_bytes(method.as_bytes()).unwrap())
        .uri(path)
        .header("content-type", "application/json")
        .header("idempotency-key", uuid::Uuid::new_v4().to_string())
        .header(sparkd::auth::HEADER_DEVICE_ID, client.device_id.to_string())
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header(sparkd::auth::HEADER_TIMESTAMP, timestamp)
        .header(sparkd::auth::HEADER_NONCE, base64url_encode(&nonce))
        .header(sparkd::auth::HEADER_CONTENT_SHA256, content_sha256)
        .header(
            sparkd::auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        );
    let builder = extra.into_iter().fold(builder, |builder, (name, value)| {
        builder.header(name, value)
    });
    builder.body(axum::body::Body::from(body_bytes)).unwrap()
}

async fn send(state: AppState, request: Request<axum::body::Body>) -> (StatusCode, Value) {
    let response = router(state).oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, value)
}

#[tokio::test]
async fn status_reports_the_source_honestly_instead_of_inventing_interfaces() {
    let (state, client, _guard) = test_state("observer");
    let (status, value) = send(
        state.clone(),
        signed_request(&state, &client, "GET", "/api/v1/network", None, vec![]),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    // Report unavailable sysfs evidence explicitly rather than claiming an observed empty network.
    assert_eq!(value["source"], "unavailable");
    assert_eq!(value["interfaces"], json!([]));
    assert_eq!(value["direct_profile"], false);
    assert_eq!(value["travel_access_point"], false);
}
