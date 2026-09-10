//! Exercise the guest role end to end: what a guest may reach, every policy refusal, and how its usage is attributed.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;

use axum::body::to_bytes;
use axum::http::{HeaderValue, Method, Request, StatusCode};
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey;
use parking_lot::Mutex;
use rand::RngCore;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use sparkd::auth;
use sparkd::clock::ManualUtcClock;
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::guest::{GrantState, GuestPolicy, HourWindow, WeeklySchedule};
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

/// 2026-07-01T19:00 in London (18:00 UTC), a Wednesday inside an 18:00-23:00 window.
const SUMMER_EVENING: i64 = 1_782_928_800;

struct Household {
    state: AppState,
    clock: Arc<ManualUtcClock>,
    owner: Signer,
    guest: Signer,
    _directory: tempfile::TempDir,
}

struct Signer {
    key: p256::ecdsa::SigningKey,
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

fn seed(connection: &rusqlite::Connection, role: &str) -> Signer {
    let key = fresh_key();
    let device_id = uuid::Uuid::new_v4();
    let spki = key
        .verifying_key()
        .to_public_key_der()
        .expect("spki")
        .as_bytes()
        .to_vec();
    sparkd::store::insert_device(
        connection,
        &device_id,
        "household device",
        "ios",
        &spki,
        &sha256_hex(&spki),
        role,
    )
    .expect("insert device");
    Signer { key, device_id }
}

fn evening_policy() -> GuestPolicy {
    GuestPolicy {
        state: GrantState::Active,
        display_name: "Sam".into(),
        allowed_models: vec!["qwen3-8b".into()],
        allowed_hours: WeeklySchedule::everyday(&[HourWindow {
            start_minute: 1080,
            end_minute: 1380,
        }]),
        time_zone: "Europe/London".into(),
        max_concurrent_requests: 1,
        daily_token_budget: 10_000,
        expires_at: None,
    }
}

fn household(policy: &GuestPolicy) -> Household {
    let directory = tempfile::tempdir().expect("temp");
    let mut identity = FileIdentityStore::new(directory.path().join("identity"))
        .load_or_create("guest-node")
        .expect("identity");
    identity.public.node_id = SIGNING_NODE_ID;
    let mut connection = rusqlite::Connection::open_in_memory().expect("db");
    sparkd::migration::migrate(&mut connection).expect("migrate");
    let owner = seed(&connection, "owner");
    let guest = seed(&connection, "observer");
    let invitation_id = uuid::Uuid::new_v4();
    connection
        .execute(
            "INSERT INTO pairing_invitations
                (id, role, nonce_hash, issued_by_device_id, issued_at, expires_at, signed_payload_json)
             VALUES (?1, 'guest', ?2, ?3, '2026-01-01T00:00:00Z', '2026-01-08T00:00:00Z', '{}')",
            rusqlite::params![
                invitation_id.to_string(),
                invitation_id.as_bytes().to_vec(),
                owner.device_id.to_string()
            ],
        )
        .expect("invitation row");
    sparkd::guest::insert_grant(
        &connection,
        &invitation_id,
        &owner.device_id,
        policy,
        "2026-01-01T00:00:00Z",
    )
    .expect("grant");
    sparkd::guest::bind_grant_to_device(
        &connection,
        &invitation_id,
        &guest.device_id,
        "2026-01-01T00:10:00Z",
    )
    .expect("bind");

    let clock = Arc::new(ManualUtcClock::new(
        time::OffsetDateTime::from_unix_timestamp(SUMMER_EVENING).expect("instant"),
    ));
    let state = AppState::new_with_clock(
        RuntimeConfig {
            api_major: 1,
            runtime_version: "0.1.0".to_owned(),
            listen: "127.0.0.1:0".parse().expect("listen"),
            node_name: "guest-node".to_owned(),
            data_dir: directory.path().to_path_buf(),
            advertise: false,
            tls: false,
        },
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        None,
        clock.clone(),
    )
    .with_database(Arc::new(Mutex::new(connection)));
    Household {
        state,
        clock,
        owner,
        guest,
        _directory: directory,
    }
}

fn signed(
    household: &Household,
    signer: &Signer,
    method: Method,
    path: &str,
    body: &[u8],
) -> Request<axum::body::Body> {
    // Request signing is checked against the real clock; the injected clock only drives the guest policy.
    let _ = household;
    let timestamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .expect("timestamp");
    let mut nonce_bytes = [0u8; 24];
    rand::rng().fill_bytes(&mut nonce_bytes);
    let nonce = base64url_encode(&nonce_bytes);
    let digest = sha256_hex(body);
    let canonical = auth::canonical(
        method.as_str(),
        path,
        &timestamp,
        &nonce,
        &digest,
        &signer.device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = signer.key.sign(canonical.as_bytes());
    let builder = Request::builder()
        .method(method)
        .uri(path)
        .header("idempotency-key", uuid::Uuid::new_v4().to_string())
        .header(auth::HEADER_DEVICE_ID, signer.device_id.to_string())
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

async fn send(
    household: &Household,
    signer: &Signer,
    method: Method,
    path: &str,
    body: Value,
) -> (StatusCode, Value) {
    let bytes = if body.is_null() {
        Vec::new()
    } else {
        serde_json::to_vec(&body).expect("body")
    };
    let request = signed(household, signer, method, path, &bytes);
    let response = router(household.state.clone())
        .oneshot(request)
        .await
        .expect("response");
    let status = response.status();
    let read = to_bytes(response.into_body(), 1 << 20)
        .await
        .expect("bytes");
    (status, serde_json::from_slice(&read).unwrap_or(Value::Null))
}

async fn chat(household: &Household, model: &str) -> (StatusCode, Value) {
    send(
        household,
        &household.guest,
        Method::POST,
        "/v1/chat/completions",
        json!({ "model": model, "messages": [{ "role": "user", "content": "hello" }] }),
    )
    .await
}

fn error_code(body: &Value) -> String {
    body.get("error")
        .and_then(|error| error.get("code"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn audit_reasons(household: &Household, action: &str) -> Vec<String> {
    let connection = household.state.database.as_ref().expect("db").lock();
    let mut statement = connection
        .prepare(
            "SELECT COALESCE(json_extract(details_json, '$.reason_code'), result)
               FROM audit_records WHERE action = ?1 ORDER BY sequence",
        )
        .expect("prepare");
    statement
        .query_map([action], |row| row.get::<_, String>(0))
        .expect("query")
        .collect::<Result<_, _>>()
        .expect("rows")
}

fn set_state(household: &Household, state: GrantState) {
    let connection = household.state.database.as_ref().expect("db").lock();
    sparkd::guest::set_grant_state(
        &connection,
        &household.guest.device_id,
        state,
        "2026-07-01T18:00:00Z",
    )
    .expect("state");
}

include!("guest_access/scenarios/a_guest_reaches_the_chat_gateway_and_nothing_else.rs");

include!("guest_access/scenarios/every_policy_refusal_names_its_reason_and_is_counted.rs");

include!("guest_access/scenarios/the_allowed_hours_are_read_in_the_owners_time_zone.rs");

include!("guest_access/scenarios/a_guest_sees_only_the_models_the_owner_shared.rs");

include!(
    "guest_access/scenarios/an_admitted_guest_request_is_audited_before_it_reaches_the_engine.rs"
);

include!("guest_access/scenarios/a_guest_reads_its_own_usage_and_no_one_elses.rs");

include!(
    "guest_access/scenarios/the_owner_sees_every_guest_and_revocation_takes_effect_at_once.rs"
);

include!("guest_access/scenarios/a_guest_request_carries_no_tools_to_the_engine.rs");

include!("guest_access/scenarios/household_notes_need_separate_membership.rs");
