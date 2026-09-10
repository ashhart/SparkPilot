//! Route-level tests for the findings in docs/reviews/BUG-HUNT-2026-09-05.md that need a signed request; the harness is copied from `tests/security_matrix.rs`.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;

use axum::body::to_bytes;
use axum::http::{Method, Request, StatusCode};
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey;
use parking_lot::Mutex;
use rand::RngCore;
use serde_json::Value;
use spark_core::identity::{FileIdentityStore, IdentityStore};
use sparkd::capability::Role;
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

struct Harness {
    state: AppState,
    key: p256::ecdsa::SigningKey,
    device_id: uuid::Uuid,
    _directory: tempfile::TempDir,
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

fn harness(role: &str) -> Harness {
    let directory = tempfile::tempdir().unwrap();
    let mut identity = FileIdentityStore::new(directory.path().join("identity"))
        .load_or_create("bug-hunt-node")
        .unwrap();
    identity.public.node_id = SIGNING_NODE_ID;
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut connection).unwrap();
    let key = random_signing_key();
    let device_id = uuid::Uuid::new_v4();
    let spki = key
        .verifying_key()
        .to_public_key_der()
        .unwrap()
        .as_bytes()
        .to_vec();
    sparkd::store::insert_device(
        &connection,
        &device_id,
        "bug hunt",
        "macos",
        &spki,
        &sha256_hex(&spki),
        role,
    )
    .unwrap();
    let state = AppState::new(
        RuntimeConfig {
            api_major: 1,
            runtime_version: "0.1.0".to_owned(),
            listen: "127.0.0.1:0".parse().unwrap(),
            node_name: "bug-hunt-node".to_owned(),
            data_dir: directory.path().to_path_buf(),
            advertise: false,
            tls: false,
        },
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        None,
    )
    .with_database(Arc::new(Mutex::new(connection)));
    Harness {
        state,
        key,
        device_id,
        _directory: directory,
    }
}

/// Bind a guest grant to the harness device and leave it in one named lifecycle state.
fn seed_guest_grant(harness: &Harness, state: &str) {
    let database = harness.state.database.as_ref().unwrap();
    let connection = database.lock();
    let owner = uuid::Uuid::new_v4();
    sparkd::store::insert_device(
        &connection,
        &owner,
        "owner",
        "macos",
        format!("owner-spki-{owner}").as_bytes(),
        &format!("owner-fingerprint-{owner}"),
        "owner",
    )
    .unwrap();
    let invitation = uuid::Uuid::new_v4();
    connection
        .execute(
            "INSERT INTO pairing_invitations
                (id, role, nonce_hash, issued_by_device_id, issued_at, expires_at, signed_payload_json)
             VALUES (?1, 'guest', ?2, ?3, '2026-01-01T00:00:00Z', '2026-01-08T00:00:00Z', '{}')",
            rusqlite::params![
                invitation.to_string(),
                invitation.as_bytes().to_vec(),
                owner.to_string()
            ],
        )
        .unwrap();
    let policy = sparkd::guest::GuestPolicy {
        state: sparkd::guest::GrantState::Active,
        display_name: "Sam".to_owned(),
        allowed_models: vec!["qwen3-8b".to_owned()],
        allowed_hours: sparkd::guest::WeeklySchedule::always(),
        time_zone: "Europe/London".to_owned(),
        max_concurrent_requests: 2,
        daily_token_budget: 20_000,
        expires_at: None,
    };
    sparkd::guest::insert_grant(
        &connection,
        &invitation,
        &owner,
        &policy,
        "2026-01-01T00:00:00Z",
    )
    .unwrap();
    sparkd::guest::bind_grant_to_device(
        &connection,
        &invitation,
        &harness.device_id,
        "2026-01-02T00:00:00Z",
    )
    .unwrap();
    connection
        .execute(
            "UPDATE guest_grants SET state = ?2 WHERE device_id = ?1",
            rusqlite::params![harness.device_id.to_string(), state],
        )
        .unwrap();
}

fn signed(harness: &Harness, method: &str, path: &str) -> Request<axum::body::Body> {
    signed_with_body(harness, method, path, &[])
}

fn signed_with_body(
    harness: &Harness,
    method: &str,
    path: &str,
    body: &[u8],
) -> Request<axum::body::Body> {
    let mut nonce = [0u8; 24];
    rand::rng().fill_bytes(&mut nonce);
    let timestamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let content_sha256 = sha256_hex(body);
    let canonical = sparkd::auth::canonical(
        method,
        path,
        &timestamp,
        &base64url_encode(&nonce),
        &content_sha256,
        &harness.device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = harness.key.sign(canonical.as_bytes());
    Request::builder()
        .method(Method::from_bytes(method.as_bytes()).unwrap())
        .uri(path)
        .header("content-type", "application/json")
        .header("idempotency-key", uuid::Uuid::new_v4().to_string())
        .header(
            sparkd::auth::HEADER_DEVICE_ID,
            harness.device_id.to_string(),
        )
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header(sparkd::auth::HEADER_TIMESTAMP, timestamp)
        .header(sparkd::auth::HEADER_NONCE, base64url_encode(&nonce))
        .header(sparkd::auth::HEADER_CONTENT_SHA256, content_sha256)
        .header(
            sparkd::auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        )
        .body(axum::body::Body::from(body.to_vec()))
        .unwrap()
}

async fn send(state: AppState, request: Request<axum::body::Body>) -> (StatusCode, Value) {
    let response = router(state).oneshot(request).await.unwrap();
    let status = response.status();
    // An answered event stream never ends, so on success the status is the whole assertion.
    if status == StatusCode::OK && request_is_a_stream(&response) {
        return (status, Value::Null);
    }
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

fn request_is_a_stream(response: &axum::response::Response) -> bool {
    response
        .headers()
        .get(axum::http::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.starts_with("text/event-stream"))
}

#[tokio::test]
async fn the_remote_status_document_is_owner_only_as_its_module_claims() {
    for role in ["observer", "user", "developer", "administrator"] {
        let harness = harness(role);
        let (status, body) = send(
            harness.state.clone(),
            signed(&harness, "GET", "/api/v1/remote"),
        )
        .await;
        assert_eq!(
            status,
            StatusCode::FORBIDDEN,
            "a {role} read the remote status document: {body}"
        );
        let (status, body) = send(
            harness.state.clone(),
            signed(&harness, "POST", "/api/v1/remote/refresh"),
        )
        .await;
        assert_eq!(
            status,
            StatusCode::FORBIDDEN,
            "a {role} drove a privileged overlay probe: {body}"
        );
    }
}

#[tokio::test]
async fn host_telemetry_needs_a_capability() {
    let harness = harness("observer");
    let (status, body) = send(
        harness.state.clone(),
        signed(&harness, "GET", "/api/v1/telemetry"),
    )
    .await;
    assert_ne!(
        status,
        StatusCode::OK,
        "an observer read full host telemetry with no capability check: {body}"
    );
}

#[test]
fn an_unknown_stored_role_is_the_lowest_authority_its_doc_comment_promises() {
    assert_eq!(Role::parse("something-that-does-not-exist"), Role::Guest);
    assert_eq!(Role::parse(""), Role::Guest);
}

/// BH-21: with the grant revoked and the device row not, the ex-guest used to escape the guest route restriction entirely; this is that exact half-state.
#[tokio::test]
async fn a_half_finished_revocation_never_raises_what_the_ex_guest_reaches() {
    let harness = harness("observer");
    seed_guest_grant(&harness, "revoked");

    for path in [
        "/api/v1/telemetry",
        "/api/v1/telemetry/history",
        "/api/v1/devices",
        "/api/v1/remote",
        "/api/v1/shared-access",
        "/api/v1/events",
        "/api/v1/inference/requests",
        "/api/v1/settings",
    ] {
        let (status, body) = send(harness.state.clone(), signed(&harness, "GET", path)).await;
        assert_eq!(
            status,
            StatusCode::FORBIDDEN,
            "a revoked guest whose device row was not revoked reached {path}: {body}"
        );
        assert_eq!(body["error"]["code"], "ROLE_FORBIDDEN", "{path}");
    }

    let chat = br#"{"model":"qwen3-8b","messages":[{"role":"user","content":"hi"}]}"#;
    let (_, body) = send(
        harness.state.clone(),
        signed_with_body(&harness, "POST", "/v1/chat/completions", chat),
    )
    .await;
    assert_eq!(
        body["error"]["code"], "GUEST_ACCESS_REVOKED",
        "chat must be refused as a withdrawn guest: {body}"
    );
}

/// BH-21: a grant lookup this daemon cannot answer holds the device at guest, not at its stored role.
#[tokio::test]
async fn an_unreadable_grant_holds_the_device_at_guest() {
    let harness = harness("administrator");
    {
        let database = harness.state.database.as_ref().unwrap();
        let connection = database.lock();
        connection
            .execute("DROP TABLE guest_usage", [])
            .and_then(|_| connection.execute("DROP TABLE guest_grants", []))
            .unwrap();
    }
    let (status, body) = send(
        harness.state.clone(),
        signed(&harness, "GET", "/api/v1/telemetry"),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "an administrator kept its authority through a failed guest lookup: {body}"
    );
}
