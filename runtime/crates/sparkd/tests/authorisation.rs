//! Exercise scoped authorization, audit integrity, fresh presence, concurrent replay refusal and principal rate limits.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;

use axum::body::to_bytes;
use axum::extract::ConnectInfo;
use axum::http::{HeaderValue, Method, Request, StatusCode};
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey;
use rand::RngCore;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use sparkd::auth;
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::migration;
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

struct Harness {
    state: AppState,
    _dir: tempfile::TempDir,
}

fn fresh_key() -> p256::ecdsa::SigningKey {
    loop {
        let mut scalar = [0u8; 32];
        rand::rng().fill_bytes(&mut scalar);
        if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&scalar) {
            return key;
        }
    }
}

fn spki(key: &p256::ecdsa::SigningKey) -> Vec<u8> {
    key.verifying_key()
        .to_public_key_der()
        .expect("spki")
        .as_bytes()
        .to_vec()
}

fn harness() -> Harness {
    let dir = tempfile::tempdir().expect("tempdir");
    let mut identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("authorisation-test")
        .expect("identity");
    identity.public.node_id = SIGNING_NODE_ID;
    let mut conn = rusqlite::Connection::open_in_memory().expect("db");
    migration::migrate(&mut conn).expect("migrate");
    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".to_owned(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "authorisation-test".to_owned(),
        data_dir: dir.path().to_path_buf(),
        advertise: false,
        tls: false,
    };
    let state = AppState::new(
        config,
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        Some(conn),
    );
    Harness { state, _dir: dir }
}

fn seed_device(state: &AppState, key: &p256::ecdsa::SigningKey, role: &str) -> uuid::Uuid {
    let id = uuid::Uuid::new_v4();
    let conn = state.database.as_ref().expect("db").lock();
    sparkd::store::insert_device(
        &conn,
        &id,
        "test device",
        "macos",
        &spki(key),
        &format!("fingerprint-{id}"),
        role,
    )
    .expect("seed device");
    id
}

fn register_presence_key(state: &AppState, device_id: &uuid::Uuid, key: &p256::ecdsa::SigningKey) {
    let key_spki = spki(key);
    state
        .database
        .as_ref()
        .expect("db")
        .lock()
        .execute(
            "UPDATE devices
                SET presence_public_key_spki = ?1,
                    presence_public_key_fingerprint = ?2
              WHERE id = ?3",
            rusqlite::params![
                key_spki,
                sha256_hex(key.verifying_key().to_encoded_point(false).as_bytes()),
                device_id.to_string(),
            ],
        )
        .expect("register presence key");
}

fn rfc3339_now() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .expect("rfc3339")
}

fn fresh_nonce() -> String {
    let mut nonce = [0u8; 24];
    rand::rng().fill_bytes(&mut nonce);
    base64url_encode(&nonce)
}

fn signed(
    key: &p256::ecdsa::SigningKey,
    device_id: &uuid::Uuid,
    method: Method,
    path: &str,
    body: &[u8],
    nonce: &str,
) -> Request<axum::body::Body> {
    let timestamp = rfc3339_now();
    let digest = sha256_hex(body);
    let canonical = auth::canonical(
        method.as_str(),
        path,
        &timestamp,
        nonce,
        &digest,
        device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = key.sign(canonical.as_bytes());
    let builder = Request::builder()
        .method(method)
        .uri(path)
        .header("idempotency-key", uuid::Uuid::new_v4().to_string())
        .header(auth::HEADER_DEVICE_ID, device_id.to_string())
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header(auth::HEADER_TIMESTAMP, timestamp)
        .header(auth::HEADER_NONCE, nonce)
        .header(auth::HEADER_CONTENT_SHA256, digest)
        .header(
            auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        );
    if body.is_empty() {
        builder.body(axum::body::Body::empty()).unwrap()
    } else {
        builder
            .header("content-type", HeaderValue::from_static("application/json"))
            .body(axum::body::Body::from(body.to_vec()))
            .unwrap()
    }
}

fn add_presence_proof(
    request: &mut Request<axum::body::Body>,
    key: &p256::ecdsa::SigningKey,
) -> String {
    let timestamp = request
        .headers()
        .get(auth::HEADER_TIMESTAMP)
        .unwrap()
        .to_str()
        .unwrap();
    let expires_at =
        (time::OffsetDateTime::parse(timestamp, &time::format_description::well_known::Rfc3339)
            .unwrap()
            + time::Duration::seconds(30))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let device_id = uuid::Uuid::parse_str(
        request
            .headers()
            .get(auth::HEADER_DEVICE_ID)
            .unwrap()
            .to_str()
            .unwrap(),
    )
    .unwrap();
    let canonical = spark_contracts::user_presence_canonical(
        request.method().as_str(),
        &request.uri().to_string(),
        timestamp,
        request
            .headers()
            .get(auth::HEADER_NONCE)
            .unwrap()
            .to_str()
            .unwrap(),
        request
            .headers()
            .get(auth::HEADER_CONTENT_SHA256)
            .unwrap()
            .to_str()
            .unwrap(),
        &device_id,
        &expires_at,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = key.sign(canonical.as_bytes());
    let proof = spark_contracts::UserPresenceHeader {
        version: spark_contracts::USER_PRESENCE_PROOF_VERSION,
        expires_at,
        signature: base64url_encode(&signature.to_bytes()),
    };
    let encoded = base64url_encode(&serde_json::to_vec(&proof).unwrap());
    request.headers_mut().insert(
        auth::HEADER_USER_PRESENCE,
        HeaderValue::from_str(&encoded).unwrap(),
    );
    encoded
}

async fn send(state: &AppState, request: Request<axum::body::Body>) -> (StatusCode, Value) {
    let response = router(state.clone()).oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, value)
}

include!("authorisation/scenarios/one_nonce_admits_exactly_one_concurrent_request.rs");

include!("authorisation/scenarios/a_broken_replay_store_fails_closed.rs");

include!("authorisation/scenarios/decisions_are_recorded_in_a_verifiable_chain.rs");

fn role_of(state: &AppState, device: &uuid::Uuid) -> String {
    state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT role FROM devices WHERE id = ?1",
            [device.to_string()],
            |row| row.get(0),
        )
        .unwrap()
}

include!("authorisation/scenarios/promoting_a_device_requires_the_biometric_presence_key.rs");

include!("authorisation/scenarios/a_signing_key_presence_proof_cannot_promote_a_device.rs");

include!("authorisation/scenarios/a_presence_proof_is_single_use.rs");

include!("authorisation/scenarios/rejected_authentication_is_an_administrator_scoped_event.rs");

include!("authorisation/scenarios/a_flood_of_terminal_creations_is_rate_limited.rs");

include!("authorisation/scenarios/unauthenticated_pairing_attempts_are_limited.rs");

include!(
    "authorisation/scenarios/authentication_failures_are_source_limited_before_event_growth.rs"
);

include!(
    "authorisation/scenarios/request_signature_requires_this_recipient_and_rejects_legacy_scheme.rs"
);

include!(
    "authorisation/scenarios/sole_owner_can_rename_and_repeat_the_owner_role_through_the_signed_api.rs"
);

include!(
    "authorisation/scenarios/authenticated_activity_updates_roster_last_seen_but_failed_auth_does_not.rs"
);
