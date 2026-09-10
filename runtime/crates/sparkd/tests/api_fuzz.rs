//! Fuzz fixed-seed signed/typed bodies for bounded errors, no mutation or input echo, chunk invariance and header preservation; retain reduced regressions.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

mod fuzz_support;

use std::collections::BTreeMap;
use std::sync::Arc;

use axum::body::to_bytes;
use axum::http::{Method, Request, StatusCode};
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey;
use parking_lot::Mutex;
use rusqlite::Connection;
use serde_json::Value;
use spark_core::identity::{FileIdentityStore, IdentityStore};
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

use fuzz_support::{Case, Lcg, body_corpus, regressions};

/// Seed for the corpus driven at live routes. Fixed so a CI failure replays.
const ROUTE_SEED: u64 = 0x5350_4152_4B41_5049; // "SPARKAPI"
/// Seed for the parse-only corpus driven at the typed bodies.
const PARSE_SEED: u64 = 0x5041_5253_4542_4F44; // "PARSEBOD"
/// Bound signed-stack corpus size because signing, verification and router execution dominate CI cost.
const ROUTE_CASES: usize = 1_536;
/// Bodies through the typed deserialisers alone: no signing, no router.
const PARSE_CASES: usize = 50_000;

/// Permit only refusal audit/events, consumed signed nonces and replay receipts to change; snapshot all other stored state exactly.
const OBSERVABILITY_TABLES: &[&str] = &[
    "audit_records",
    "events",
    "request_nonces",
    "idempotency_records",
];

struct Harness {
    state: AppState,
    key: p256::ecdsa::SigningKey,
    device_id: uuid::Uuid,
    nonce: std::cell::Cell<u64>,
    _directory: tempfile::TempDir,
}

fn harness() -> Harness {
    let directory = tempfile::tempdir().unwrap();
    let mut identity = FileIdentityStore::new(directory.path().join("identity"))
        .load_or_create("fuzz-node")
        .unwrap();
    identity.public.node_id = SIGNING_NODE_ID;
    let mut connection = Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut connection).unwrap();
    // A fixed key: the corpus is the variable under test, not the keypair.
    let key = p256::ecdsa::SigningKey::from_slice(&[
        0x4c, 0x1b, 0x2e, 0x7f, 0x91, 0x03, 0xa5, 0xd8, 0x6c, 0x2f, 0x40, 0x93, 0xe1, 0x77, 0x5a,
        0xb2, 0x08, 0xd4, 0x36, 0x9c, 0xfe, 0x51, 0x27, 0x8a, 0x63, 0xbd, 0x14, 0x0e, 0x79, 0xc3,
        0x82, 0x45,
    ])
    .unwrap();
    let device_id = uuid::Uuid::from_u128(0x5350_4152_4B44_4556_4943_4546_555A_5A00);
    let spki = key
        .verifying_key()
        .to_public_key_der()
        .unwrap()
        .as_bytes()
        .to_vec();
    sparkd::store::insert_device(
        &connection,
        &device_id,
        "fuzz device",
        "macos",
        &spki,
        &sha256_hex(&spki),
        "owner",
    )
    .unwrap();
    let state = AppState::new(
        RuntimeConfig {
            api_major: 1,
            runtime_version: "0.1.0".to_owned(),
            listen: "127.0.0.1:0".parse().unwrap(),
            node_name: "fuzz-node".to_owned(),
            data_dir: directory.path().to_path_buf(),
            advertise: false,
            tls: false,
        },
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        None,
    )
    .with_database(Arc::new(Mutex::new(connection)));
    // Disable throttling for parser corpus cases so they reach deserialization rather than measuring rate limits.
    let mut state = state;
    state.rate_limiter = sparkd::ratelimit::RateLimiter::disabled(state.clock.clone());
    Harness {
        state,
        key,
        device_id,
        nonce: std::cell::Cell::new(0),
        _directory: directory,
    }
}

/// Sign arbitrary body bytes correctly so authentication succeeds and only body handling is under test.
fn signed(harness: &Harness, method: &str, path: &str, body: &[u8]) -> Request<axum::body::Body> {
    let count = harness.nonce.get() + 1;
    harness.nonce.set(count);
    let nonce = base64url_encode(&count.to_be_bytes());
    let timestamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let content_sha256 = sha256_hex(body);
    let canonical = sparkd::auth::canonical(
        method,
        path,
        &timestamp,
        &nonce,
        &content_sha256,
        &harness.device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = harness.key.sign(canonical.as_bytes());
    Request::builder()
        .method(Method::from_bytes(method.as_bytes()).unwrap())
        .uri(path)
        .header("content-type", "application/json")
        .header(
            "idempotency-key",
            uuid::Uuid::from_u128(count as u128).to_string(),
        )
        .header(
            sparkd::auth::HEADER_DEVICE_ID,
            harness.device_id.to_string(),
        )
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header(sparkd::auth::HEADER_TIMESTAMP, timestamp)
        .header(sparkd::auth::HEADER_NONCE, nonce)
        .header(sparkd::auth::HEADER_CONTENT_SHA256, content_sha256)
        .header(
            sparkd::auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        )
        .body(axum::body::Body::from(body.to_vec()))
        .unwrap()
}

async fn send(state: AppState, request: Request<axum::body::Body>) -> (StatusCode, Vec<u8>) {
    let response = router(state).oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1 << 22).await.unwrap();
    (status, bytes.to_vec())
}

/// Snapshot every non-observability row's values so comparisons detect updates as well as insertions.
fn stored_state(
    database: &Arc<Mutex<Connection>>,
    authenticated_device: &uuid::Uuid,
) -> BTreeMap<String, Vec<String>> {
    let connection = database.lock();
    let tables: Vec<String> = connection
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    let mut dump = BTreeMap::new();
    for table in tables {
        if OBSERVABILITY_TABLES.contains(&table.as_str()) || table.starts_with("sqlite_") {
            continue;
        }
        let mut statement = connection
            .prepare(&format!("SELECT * FROM \"{table}\""))
            .unwrap();
        let columns = statement.column_count();
        // Allow only the authenticated caller's last-seen timestamp to change; retain exact snapshots for grants, keys and other devices.
        let activity_columns = if table == "devices" {
            Some((
                statement.column_index("id").unwrap(),
                statement.column_index("last_seen_at").unwrap(),
            ))
        } else {
            None
        };
        let authenticated_device = authenticated_device.to_string();
        let rows: Vec<String> = statement
            .query_map([], |row| {
                let mut cells = Vec::with_capacity(columns);
                for index in 0..columns {
                    if let Some((id_column, seen_column)) = activity_columns
                        && index == seen_column
                        && row.get::<_, String>(id_column)? == authenticated_device
                    {
                        cells.push("authenticated last-seen activity".to_owned());
                        continue;
                    }
                    cells.push(format!("{:?}", row.get_ref(index)?));
                }
                Ok(cells.join("\u{1f}"))
            })
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        let mut rows = rows;
        rows.sort();
        dump.insert(table, rows);
    }
    dump
}

/// Exercise database-only routes end-to-end and subsystem-dependent bodies with parse-only cases to avoid measuring missing test services.
fn body_routes() -> Vec<(
    &'static str,
    &'static str,
    &'static [&'static str],
    &'static str,
)> {
    vec![
        (
            "POST",
            "/api/v1/settings/telemetry",
            &["functional", "technical"],
            r#"{"functional":true,"technical":false}"#,
        ),
        (
            "POST",
            "/api/v1/settings/memory-guard",
            &[
                "warning_available_bytes",
                "critical_available_bytes",
                "emergency_available_bytes",
            ],
            r#"{"warning_available_bytes":8000000000,"critical_available_bytes":4000000000,"emergency_available_bytes":2000000000}"#,
        ),
        (
            "POST",
            "/api/v1/settings/model-idle",
            &["model_id", "profile_id", "idle_policy"],
            r#"{"model_id":"example/model-32b","profile_id":"balanced-32k","idle_policy":"keep_loaded"}"#,
        ),
        (
            "PATCH",
            "/api/v1/devices/00000000-0000-4000-8000-000000000001",
            &["display_name", "role"],
            r#"{"display_name":"studio mac","role":"user"}"#,
        ),
    ]
}

include!("api_fuzz/scenarios/a_refused_body_is_a_client_error_that_changes_no_stored_state.rs");

include!("api_fuzz/scenarios/a_refusal_never_echoes_the_body_back.rs");

include!(
    "api_fuzz/scenarios/rewriting_a_refusal_keeps_its_headers_and_leaves_json_refusals_alone.rs"
);

include!("api_fuzz/scenarios/a_rate_limited_refusal_keeps_its_retry_after.rs");

include!("api_fuzz/scenarios/a_body_over_the_limit_is_refused.rs");

include!("api_fuzz/scenarios/the_typed_bodies_reject_the_corpus_without_panicking.rs");

include!("api_fuzz/scenarios/the_answer_does_not_depend_on_how_the_body_was_chunked.rs");
