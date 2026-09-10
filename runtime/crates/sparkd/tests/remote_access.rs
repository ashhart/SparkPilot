//! Exercise owner-signed Tailscale setup, route recovery, fresh presence and durable remote operations.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;
use std::time::Duration;

use axum::body::to_bytes;
use axum::http::{Method, Request, StatusCode};
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey;
use parking_lot::Mutex;
use rand::RngCore;
use rusqlite::Connection;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use sparkd::auth;
use sparkd::clock::ManualUtcClock;
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::remote::{PrivateOverlayProbe, PrivateOverlayRoute, RemoteAccessService};
use sparkd::remote_overlay_setup::{
    OverlayRollback, OverlayRollbackReport, OverlaySetup, OverlaySetupState,
    PrivateOverlayProvisioner, ProvisionedOverlayProbe,
};
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

struct TestClient {
    key: p256::ecdsa::SigningKey,
    presence_key: p256::ecdsa::SigningKey,
    device_id: uuid::Uuid,
    role: &'static str,
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

fn migrated_db() -> Connection {
    let mut conn = Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut conn).expect("migrations apply");
    conn
}

fn seed_device(conn: &Connection, client: &TestClient) {
    let spki = client
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
    let presence_fingerprint = sha256_hex(&presence_spki);
    sparkd::store::insert_device_with_presence_key(
        conn,
        &client.device_id,
        "test client",
        "macos",
        &spki,
        &sha256_hex(&spki),
        client.role,
        Some((&presence_spki, &presence_fingerprint)),
    )
    .unwrap();
}

fn signed_request(
    client: &TestClient,
    method: &str,
    path: &str,
    body: Option<&Value>,
    extra_headers: Vec<(&'static str, String)>,
) -> Request<axum::body::Body> {
    signed_request_with_options(
        client,
        method,
        path,
        body,
        extra_headers,
        uuid::Uuid::new_v4(),
        Some(path),
    )
}

fn signed_request_with_options(
    client: &TestClient,
    method: &str,
    path: &str,
    body: Option<&Value>,
    extra_headers: Vec<(&'static str, String)>,
    idempotency_key: uuid::Uuid,
    presence_path: Option<&str>,
) -> Request<axum::body::Body> {
    let body_bytes = body
        .map(|value| serde_json::to_vec(value).unwrap())
        .unwrap_or_default();
    let mut nonce = [0u8; 24];
    rand::rng().fill_bytes(&mut nonce);
    let nonce = base64url_encode(&nonce);
    let request_time = time::OffsetDateTime::now_utc();
    let timestamp = request_time
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let content_sha256 = sha256_hex(&body_bytes);
    let canonical = auth::canonical(
        method,
        path,
        &timestamp,
        &nonce,
        &content_sha256,
        &client.device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = client.key.sign(canonical.as_bytes());
    let presence = presence_path.map(|presence_path| {
        let expires_at = (request_time + time::Duration::seconds(45))
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap();
        let canonical = spark_contracts::user_presence_canonical(
            method,
            presence_path,
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
        base64url_encode(&serde_json::to_vec(&proof).unwrap())
    });
    let builder = Request::builder()
        .method(Method::from_bytes(method.as_bytes()).unwrap())
        .uri(path)
        .header("content-type", "application/json")
        .header("idempotency-key", idempotency_key.to_string())
        .header(auth::HEADER_DEVICE_ID, client.device_id.to_string())
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header(auth::HEADER_TIMESTAMP, timestamp)
        .header(auth::HEADER_NONCE, nonce)
        .header(auth::HEADER_CONTENT_SHA256, content_sha256)
        .header(
            auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        );
    let builder = if let Some(presence) = presence {
        builder.header(sparkd::user_presence::HEADER_USER_PRESENCE, presence)
    } else {
        builder
    };
    let builder = extra_headers
        .into_iter()
        .fold(builder, |builder, (name, value)| {
            builder.header(name, value)
        });
    builder.body(axum::body::Body::from(body_bytes)).unwrap()
}

async fn send(state: AppState, request: Request<axum::body::Body>) -> (StatusCode, Value) {
    let response = router(state).oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or(Value::Null)
    };
    (status, value)
}

/// Obtain fresh signed presence for elevated remote enable/disable actions.
async fn presence_header(state: &AppState, client: &TestClient) -> Vec<(&'static str, String)> {
    let request = signed_request(client, "POST", "/api/v1/presence/challenge", None, vec![]);
    let (status, issued) = send(state.clone(), request).await;
    assert_eq!(status, StatusCode::CREATED, "presence challenge: {issued}");
    let challenge_id = uuid::Uuid::parse_str(issued["challenge_id"].as_str().unwrap()).unwrap();
    let challenge = sparkd::crypto::base64url_decode(issued["challenge"].as_str().unwrap())
        .expect("challenge is base64url");
    let input = sparkd::presence::signing_input(
        &challenge,
        &challenge_id,
        &client.device_id,
        &state.identity.node_id().to_string(),
    );
    let signature: p256::ecdsa::Signature = client.key.sign(&input);
    vec![(
        "x-spark-user-presence",
        format!("{challenge_id}.{}", base64url_encode(&signature.to_bytes())),
    )]
}

#[derive(Debug, Default)]
struct AvailableTailscale;

impl PrivateOverlayProbe for AvailableTailscale {
    fn route(&self) -> Result<Option<PrivateOverlayRoute>, String> {
        Ok(Some(PrivateOverlayRoute {
            provider: "tailscale".into(),
            hostname: "100.96.4.2".into(),
            address: Some("100.96.4.2".into()),
        }))
    }
}

fn test_state(
    role: &'static str,
) -> (
    AppState,
    TestClient,
    Arc<Mutex<Connection>>,
    tempfile::TempDir,
) {
    let dir = tempfile::tempdir().unwrap();
    let mut identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("test-node")
        .unwrap();
    identity.public.node_id = SIGNING_NODE_ID;
    let conn = migrated_db();
    let client = TestClient {
        key: random_signing_key(),
        presence_key: random_signing_key(),
        device_id: uuid::Uuid::new_v4(),
        role,
    };
    seed_device(&conn, &client);

    let database = Arc::new(Mutex::new(conn));
    let clock = Arc::new(ManualUtcClock::new(time::OffsetDateTime::now_utc()));
    let node_id = identity.node_id().to_string();
    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".to_owned(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "test-node".to_owned(),
        data_dir: dir.path().to_path_buf(),
        advertise: false,
        tls: false,
    };
    let state = AppState::new_with_clock(
        config,
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        None,
        clock,
    )
    .with_database(database.clone());
    let mut service = RemoteAccessService::new(database.clone(), state.events.clone(), node_id);
    service = service.with_private_overlay_probe(Arc::new(AvailableTailscale));
    let service = Arc::new(service);
    let state = state.with_remote(service);
    (state, client, database, dir)
}

fn wait_for_remote_operation(database: &Arc<Mutex<Connection>>, operation_id: &str) -> String {
    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(20));
        let state = database
            .lock()
            .query_row(
                "SELECT state FROM operations WHERE id = ?1",
                [operation_id],
                |row| row.get::<_, String>(0),
            )
            .ok();
        if let Some(state) = state
            && !matches!(state.as_str(), "requested" | "queued" | "running")
        {
            return state;
        }
    }
    "timeout".into()
}

async fn preview_enable_body(
    state: &AppState,
    client: &TestClient,
    mode: &str,
    token: Option<&str>,
) -> Value {
    let mut body = json!({ "mode": mode });
    if let Some(token) = token {
        body["registration_token"] = Value::String(token.to_owned());
    }
    let (status, preview) = send(
        state.clone(),
        signed_request(
            client,
            "POST",
            "/api/v1/remote/enable/preview",
            Some(&body),
            vec![],
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "enable preview: {preview}");
    body["accepted_preview_digest"] = preview["preview_digest"].clone();
    body
}

async fn preview_disable_body(state: &AppState, client: &TestClient) -> Value {
    let (status, preview) = send(
        state.clone(),
        signed_request(
            client,
            "POST",
            "/api/v1/remote/disable/preview",
            None,
            vec![],
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "disable preview: {preview}");
    json!({ "accepted_preview_digest": preview["preview_digest"] })
}

include!("remote_access/one_tap_support.rs");
include!("remote_access/scenarios/tailscale_preference_authority.rs");
include!("remote_access/scenarios/tailscale_preference_operations.rs");

include!(
    "remote_access/scenarios/one_tap_enable_prepares_tailscale_waits_for_the_owner_sign_in_and_publishes_the_magicdns_route.rs"
);

include!(
    "remote_access/scenarios/a_sign_in_that_never_completes_fails_the_enable_with_a_timeout_and_keeps_remote_off.rs"
);

include!(
    "remote_access/scenarios/overlay_setup_status_is_owner_only_and_reports_the_helpers_state.rs"
);

include!(
    "remote_access/scenarios/a_spark_without_a_helper_still_blocks_the_review_with_a_next_action.rs"
);

include!("remote_access/scenarios/remote_status_is_disabled_by_default.rs");

include!(
    "remote_access/scenarios/aggregate_status_can_read_the_configured_mode_without_a_route_probe.rs"
);

include!(
    "remote_access/scenarios/missing_private_overlay_is_reported_and_never_changes_remote_state.rs"
);

include!("remote_access/scenarios/disappearing_overlay_invalidates_the_accepted_review.rs");

include!("remote_access/scenarios/enable_requires_owner_role.rs");

include!("remote_access/scenarios/enable_validates_mode_before_requesting_presence.rs");

include!("remote_access/scenarios/remote_mutations_require_exact_fresh_presence.rs");

include!(
    "remote_access/scenarios/idempotent_remote_replay_does_not_require_a_second_presence_proof.rs"
);

include!("remote_access/scenarios/disabling_private_overlay_keeps_local_pairing_and_tailscale.rs");

include!(
    "remote_access/scenarios/overlay_health_tracks_reachability_and_adopts_a_rotated_address.rs"
);

include!("remote_access/scenarios/remote_refresh_endpoint_reconciles_overlay_health_on_demand.rs");

#[tokio::test]
async fn retired_public_remote_mode_cannot_be_enabled() {
    let (state, client, database, _guard) = test_state("owner");
    let body = json!({"mode": "cloudflare_public", "accepted_preview_digest": "0".repeat(64)});
    let (status, value) = send(
        state,
        signed_request(
            &client,
            "POST",
            "/api/v1/remote/enable",
            Some(&body),
            vec![],
        ),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(value["error"]["code"], "REMOTE_MODE_INVALID");
    let operations: i64 = database
        .lock()
        .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
        .unwrap();
    assert_eq!(operations, 0);
}

include!("remote_access/scenarios/a_timed_out_enable_undoes_the_tailscale_setup_it_started.rs");
