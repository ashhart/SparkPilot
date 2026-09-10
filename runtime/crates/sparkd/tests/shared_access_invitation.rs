//! Exercise the shared-access invitation: what it carries, that it is single use, expires, and cannot be altered.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;

use axum::body::to_bytes;
use axum::http::{HeaderValue, Method, Request, StatusCode};
use ed25519_dalek::Signer as _;
use p256::pkcs8::EncodePublicKey;
use parking_lot::Mutex;
use rand::RngCore;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore, NodeIdentity};
use sparkd::auth;
use sparkd::crypto::{base64_encode, base64url_decode, base64url_encode, sha256_hex};
use sparkd::pairing::InvitationPayload;
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

struct Node {
    state: AppState,
    identity: NodeIdentity,
    owner: Keys,
    _directory: tempfile::TempDir,
}

struct Keys {
    device: p256::ecdsa::SigningKey,
    presence: p256::ecdsa::SigningKey,
    device_id: uuid::Uuid,
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

fn presence_fingerprint(key: &p256::ecdsa::SigningKey) -> String {
    sha256_hex(key.verifying_key().to_encoded_point(false).as_bytes())
}

fn node() -> Node {
    let directory = tempfile::tempdir().expect("temp");
    let mut identity = FileIdentityStore::new(directory.path().join("identity"))
        .load_or_create("shared-node")
        .expect("identity");
    identity.public.node_id = SIGNING_NODE_ID;
    let mut connection = rusqlite::Connection::open_in_memory().expect("db");
    sparkd::migration::migrate(&mut connection).expect("migrate");
    let owner = Keys {
        device: fresh_key(),
        presence: fresh_key(),
        device_id: uuid::Uuid::new_v4(),
    };
    let device_spki = spki(&owner.device);
    let presence_spki = spki(&owner.presence);
    sparkd::store::insert_device_with_presence_key(
        &connection,
        &owner.device_id,
        "owner iPhone",
        "ios",
        &device_spki,
        &sha256_hex(&device_spki),
        "owner",
        Some((
            presence_spki.as_slice(),
            presence_fingerprint(&owner.presence).as_str(),
        )),
    )
    .expect("owner device");
    let state = AppState::new(
        RuntimeConfig {
            api_major: 1,
            runtime_version: "0.1.0".to_owned(),
            listen: "127.0.0.1:7443".parse().expect("listen"),
            node_name: "Alex's Spark".to_owned(),
            data_dir: directory.path().to_path_buf(),
            advertise: false,
            tls: false,
        },
        identity.clone(),
        Arc::new(spark_telemetry::FakeSystemMonitor),
        None,
    )
    .with_database(Arc::new(Mutex::new(connection)))
    .with_tls_fingerprint("a".repeat(64));
    Node {
        state,
        identity,
        owner,
        _directory: directory,
    }
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
    timestamp: &str,
    nonce: &str,
) -> Request<axum::body::Body> {
    let digest = sha256_hex(body);
    let canonical = auth::canonical(
        method.as_str(),
        path,
        timestamp,
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
        builder.body(axum::body::Body::empty()).expect("request")
    } else {
        builder
            .header("content-type", HeaderValue::from_static("application/json"))
            .body(axum::body::Body::from(body.to_vec()))
            .expect("request")
    }
}

/// Sign the owner request and attach a fresh presence proof from the separately enrolled key.
fn with_presence(
    node: &Node,
    method: Method,
    path: &str,
    body: &[u8],
) -> Request<axum::body::Body> {
    let timestamp = rfc3339_now();
    let nonce = fresh_nonce();
    let expires_at = (time::OffsetDateTime::now_utc() + time::Duration::seconds(30))
        .format(&time::format_description::well_known::Rfc3339)
        .expect("rfc3339");
    let canonical = spark_contracts::user_presence_canonical(
        method.as_str(),
        path,
        &timestamp,
        &nonce,
        &sha256_hex(body),
        &node.owner.device_id,
        &expires_at,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = node.owner.presence.sign(canonical.as_bytes());
    let proof = spark_contracts::UserPresenceHeader {
        version: spark_contracts::USER_PRESENCE_PROOF_VERSION,
        expires_at,
        signature: base64url_encode(&signature.to_bytes()),
    };
    let mut request = signed(
        &node.owner.device,
        &node.owner.device_id,
        method,
        path,
        body,
        &timestamp,
        &nonce,
    );
    request.headers_mut().insert(
        sparkd::user_presence::HEADER_USER_PRESENCE,
        HeaderValue::from_str(&base64url_encode(
            &serde_json::to_vec(&proof).expect("proof"),
        ))
        .expect("header"),
    );
    request
}

async fn run(node: &Node, request: Request<axum::body::Body>) -> (StatusCode, Value) {
    let response = router(node.state.clone())
        .oneshot(request)
        .await
        .expect("response");
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("bytes");
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

fn limits() -> Value {
    let days: Vec<Value> = (0..7)
        .map(|weekday| {
            json!({
                "weekday": weekday,
                "windows": [{ "start_minute": 0, "end_minute": 1440 }]
            })
        })
        .collect();
    json!({
        "display_name": "Sam",
        "allowed_models": ["qwen3-8b"],
        "allowed_hours": days,
        "time_zone": "Europe/London",
        "max_concurrent_requests": 1,
        "daily_token_budget": 10000
    })
}

async fn create_invitation(node: &Node) -> (StatusCode, Value) {
    let body = serde_json::to_vec(&limits()).expect("body");
    let request = with_presence(
        node,
        Method::POST,
        "/api/v1/shared-access/invitations",
        &body,
    );
    run(node, request).await
}

fn error_code(body: &Value) -> String {
    body.pointer("/error/code")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

/// Re-sign an altered payload with the node authority, to show that only tampering without the key is caught.
fn resign(identity: &NodeIdentity, payload: &mut InvitationPayload) {
    payload.signature = None;
    let canonical = payload.canonical_without_signature().expect("canonical");
    let signature = identity.signing_key().sign(&canonical);
    payload.signature = Some(base64url_encode(&signature.to_bytes()));
}

async fn claim(node: &Node, payload: &InvitationPayload, guest: &Keys) -> (StatusCode, Value) {
    let challenge_body = serde_json::to_vec(&json!({
        "invitation_id": payload.invitation_id,
        "device_public_key_spki": base64_encode(&spki(&guest.device)),
    }))
    .expect("body");
    let (status, challenge) = run(
        node,
        Request::builder()
            .method(Method::POST)
            .uri("/api/v1/pairing/challenge")
            .header("content-type", "application/json")
            .body(axum::body::Body::from(challenge_body))
            .expect("request"),
    )
    .await;
    if status != StatusCode::OK {
        return (status, challenge);
    }
    let challenge_id: uuid::Uuid =
        serde_json::from_value(challenge["challenge_id"].clone()).expect("challenge id");
    let challenge_bytes =
        base64url_decode(challenge["challenge"].as_str().expect("challenge")).expect("decode");
    let fingerprint = presence_fingerprint(&guest.presence);
    let material = spark_contracts::pairing_presence_canonical(
        &base64url_encode(&challenge_bytes),
        &payload.invitation_id,
        &guest.device_id,
        &SIGNING_NODE_ID,
        &fingerprint,
    )
    .into_bytes();
    let device_signature: p256::ecdsa::Signature = guest.device.sign(&material);
    let presence_signature: p256::ecdsa::Signature = guest.presence.sign(&material);
    let body = serde_json::to_vec(&json!({
        "invitation": payload,
        "challenge_id": challenge_id,
        "device_id": guest.device_id,
        "device_name": "Sam's iPhone",
        "platform": "ios",
        "device_public_key_spki": base64_encode(&spki(&guest.device)),
        "presence_public_key_spki": base64_encode(&spki(&guest.presence)),
        "presence_key_signature": base64url_encode(&presence_signature.to_bytes()),
        "challenge_signature": base64url_encode(&device_signature.to_bytes()),
    }))
    .expect("body");
    run(
        node,
        Request::builder()
            .method(Method::POST)
            .uri("/api/v1/pairing/claim")
            .header("content-type", "application/json")
            .body(axum::body::Body::from(body))
            .expect("request"),
    )
    .await
}

fn guest_keys() -> Keys {
    Keys {
        device: fresh_key(),
        presence: fresh_key(),
        device_id: uuid::Uuid::new_v4(),
    }
}

include!(
    "shared_access_invitation/scenarios/the_invitation_carries_the_routes_the_pin_and_the_limits.rs"
);

include!(
    "shared_access_invitation/scenarios/an_altered_invitation_is_refused_because_it_is_signed.rs"
);

include!("shared_access_invitation/scenarios/an_invitation_is_used_once_and_expires.rs");

include!("shared_access_invitation/scenarios/a_joined_guest_waits_for_the_owner_to_confirm.rs");

include!(
    "shared_access_invitation/scenarios/an_invitation_needs_the_owners_presence_and_valid_limits.rs"
);
