//! Reject diagnostic leakage of secrets, unrequested identity details and unsafe archive paths, including future sections.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;

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

/// Use distinctive planted values so secret leakage cannot be mistaken for incidental substring matches.
const PLANTED_CREDENTIAL_REFERENCE: &str = "planted-hugging-face-secret-reference";
const PLANTED_REMOTE_HOSTNAME: &str = "planted-owner-hostname.example.invalid";
const PLANTED_PROMPT: &str = "planted-private-prompt-text";
/// Plant an ordinary prompt without secret markers to prove allowlist projection rather than keyword scrubbing.
const PLANTED_ENGINE_PROMPT: &str = "draft three paragraphs about the summer we spent at the lake";
/// Plant arbitrary text in enum-shaped fields to verify exports enforce closed vocabularies.
const PLANTED_FREE_TEXT: &str = "arbitrary /home/owner/private text";

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

fn test_state(role: &str) -> (AppState, TestClient, tempfile::TempDir) {
    test_state_with_logs(role, hostile_engine_log())
}

/// A log tail far past both caps, whose last line is an ordinary prompt.
fn hostile_engine_log() -> Vec<u8> {
    let mut lines: Vec<String> = (0..5_000)
        .map(|index| {
            format!(
                "2026-09-01T00:00:00Z INFO serving request {index} {}",
                "x".repeat(200)
            )
        })
        .collect();
    lines.push(PLANTED_ENGINE_PROMPT.to_owned());
    lines.join("\n").into_bytes()
}

fn test_state_with_logs(
    role: &str,
    engine_log: Vec<u8>,
) -> (AppState, TestClient, tempfile::TempDir) {
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
    plant_secrets(&connection, &client.device_id);

    let database = Arc::new(Mutex::new(connection));
    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".into(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "planted-node-name".into(),
        data_dir: directory.path().to_path_buf(),
        advertise: false,
        tls: false,
    };
    let socket = directory.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    let backend = FakeBackend::default();
    backend
        .scripted_logs
        .lock()
        .unwrap()
        .insert("engine".to_owned(), engine_log);
    backend.scripted_logs.lock().unwrap().insert(
        "sparkd".to_owned(),
        structured_log_with_prompt().into_bytes(),
    );
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
    (state, client, directory)
}

/// Place prompt text in structured log fields the export projection must discard.
fn structured_log_with_prompt() -> String {
    json!({
        "timestamp": "2026-09-01T00:00:00.000Z",
        "level": "INFO",
        "service": "sparkd",
        "event": "model.load.started",
        "message": PLANTED_ENGINE_PROMPT,
        "fields": { "message": PLANTED_ENGINE_PROMPT },
    })
    .to_string()
}

/// Populate real secret-adjacent storage rows so leak assertions do not pass against empty data.
fn plant_secrets(connection: &Connection, device_id: &uuid::Uuid) {
    connection
        .execute(
            "INSERT INTO provider_credentials \
             (id, provider, display_name, secret_reference, created_by_device_id, created_at) \
             VALUES (?1, 'huggingface', 'planted', ?2, ?3, '2026-09-01T00:00:00Z')",
            rusqlite::params![
                uuid::Uuid::new_v4().to_string(),
                PLANTED_CREDENTIAL_REFERENCE,
                device_id.to_string(),
            ],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO remote_access \
             (singleton, enabled, mode, hostname, health, updated_at) \
             VALUES (1, 1, 'private_overlay', ?1, ?2, '2026-09-01T00:00:00Z')",
            rusqlite::params![PLANTED_REMOTE_HOSTNAME, PLANTED_FREE_TEXT,],
        )
        .unwrap();
    // Summarize the operation while excluding its prompt-bearing stored input.
    connection
        .execute(
            "INSERT INTO operations \
             (id, kind, state, actor_device_id, created_at, updated_at, cancellable, input_json) \
             VALUES (?1, 'inference.analysis', 'succeeded', ?2, \
                     '2026-09-01T00:00:00Z', '2026-09-01T00:00:01Z', 0, ?3)",
            rusqlite::params![
                uuid::Uuid::new_v4().to_string(),
                device_id.to_string(),
                json!({ "prompt": PLANTED_PROMPT }).to_string(),
            ],
        )
        .unwrap();
    // Test pressure export against free text inserted into expected-vocabulary fields.
    connection
        .execute(
            "INSERT INTO events \
             (event_id, event_type, severity, occurred_at, node_id, payload_json) \
             VALUES (?1, 'node.memory.pressure.changed', 'warning', \
                     '2026-09-01T00:00:00Z', 'test-node', ?2)",
            rusqlite::params![
                uuid::Uuid::new_v4().to_string(),
                json!({
                    "from": PLANTED_FREE_TEXT,
                    "to": "warning",
                    "reason": PLANTED_FREE_TEXT,
                    "available_bytes": 1_024,
                })
                .to_string(),
            ],
        )
        .unwrap();
    // Seed a model, profile and active instance so engine logs and inventory sections are actually exercised.
    connection
        .execute(
            "INSERT INTO models \
             (id, recipe_revision, recipe_digest, source_revision, display_name, install_state) \
             VALUES ('acme/model', '1', 'digest', 'r1', 'Acme', 'installed')",
            [],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO model_profiles \
             (model_id, profile_id, context_length, max_sequences, max_batched_tokens, \
              gpu_memory_utilisation) \
             VALUES ('acme/model', 'balanced', 16384, 4, 8192, 0.4)",
            [],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO inference_instances \
             (id, model_id, profile_id, node_id, state, started_at) \
             VALUES (?1, 'acme/model', 'balanced', 'test-node', 'ready', '2026-09-01T00:00:00Z')",
            rusqlite::params![uuid::Uuid::new_v4().to_string()],
        )
        .unwrap();
    // Create a legal SQLite table name containing identifier delimiters to test safe row-count queries.
    connection
        .execute(
            "CREATE TABLE \"evil\"\"; DROP TABLE devices; --\" (value TEXT)",
            [],
        )
        .unwrap();
}

fn signed_request(
    client: &TestClient,
    method: Method,
    path: &str,
    body: Vec<u8>,
    include_presence: bool,
) -> Request<axum::body::Body> {
    let mut nonce = [0; 24];
    rand::rng().fill_bytes(&mut nonce);
    let nonce = base64url_encode(&nonce);
    let now = time::OffsetDateTime::now_utc();
    let timestamp = now
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let content_sha256 = sha256_hex(&body);
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
    let mut builder = Request::builder()
        .method(method.clone())
        .uri(path)
        .header("content-type", "application/json")
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
            method.as_str(),
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
    let bytes = to_bytes(response.into_body(), 8 << 20).await.unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

fn export_body(include_optional: &[&str]) -> Vec<u8> {
    serde_json::to_vec(&json!({ "include_optional": include_optional })).unwrap()
}

async fn export(state: AppState, client: &TestClient, include_optional: &[&str]) -> Value {
    let (status, bundle) = send(
        state,
        signed_request(
            client,
            Method::POST,
            "/api/v1/diagnostics/export",
            export_body(include_optional),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{bundle}");
    bundle
}

include!("diagnostics_export/scenarios/the_catalogue_defaults_every_sensitive_category_off.rs");

include!(
    "diagnostics_export/scenarios/export_requires_administrator_authority_and_fresh_presence.rs"
);

/// A refused export must leave a refusal in the trail and no acceptance.
fn assert_no_accepted_export(state: &AppState, context: &str) {
    let database = state.database.clone().unwrap();
    let connection = database.lock();
    let accepted: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM audit_records \
             WHERE action LIKE 'diagnostics.export%' AND result = 'accepted'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        accepted, 0,
        "{context} left an accepted export audit record"
    );
    let refused: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM audit_records \
             WHERE action = 'diagnostics.export' AND result = 'refused'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(refused, 1, "{context} left no refusal in the trail");
}

/// Require every diagnostics section so silently omitted categories fail the suite.
const REQUIRED_SECTIONS: &[&str] = &[
    "runtime.json",
    "host.json",
    "services.json",
    "logs.json",
    "operations.json",
    "events.json",
    "memory-pressure.json",
    "models.json",
    "network.json",
    "cluster.json",
    "database.json",
    "audit.json",
];

fn section(bundle: &Value, path: &str) -> Value {
    let file = bundle["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|file| file["path"] == path)
        .unwrap_or_else(|| panic!("{path} is not in the bundle"));
    serde_json::from_str(file["content"].as_str().unwrap()).unwrap()
}

include!(
    "diagnostics_export/scenarios/every_plan_46_1_category_is_present_with_its_required_fields.rs"
);

include!("diagnostics_export/scenarios/a_hostile_table_name_cannot_break_the_row_count_query.rs");

include!("diagnostics_export/scenarios/an_engine_prompt_never_survives_the_log_projection.rs");

include!("diagnostics_export/scenarios/an_enum_shaped_field_carries_no_arbitrary_string.rs");

include!("diagnostics_export/scenarios/a_default_bundle_names_no_host_path.rs");

include!(
    "diagnostics_export/scenarios/the_default_bundle_carries_nothing_the_owner_did_not_ask_for.rs"
);

include!("diagnostics_export/scenarios/an_opted_in_category_is_included_and_labelled.rs");

include!("diagnostics_export/scenarios/an_unknown_category_is_refused_rather_than_ignored.rs");

include!("diagnostics_export/scenarios/the_manifest_describes_every_file_and_matches_its_bytes.rs");

include!("diagnostics_export/scenarios/no_bundle_path_can_escape_the_archive.rs");

include!("diagnostics_export/scenarios/planted_secrets_never_reach_any_bundle.rs");

include!(
    "diagnostics_export/scenarios/the_export_is_audited_without_recording_what_it_contained.rs"
);

include!("diagnostics_export/scenarios/the_export_writes_nothing_to_the_node.rs");

fn listing(root: &std::path::Path) -> Vec<String> {
    let mut found = Vec::new();
    let mut queue = vec![root.to_path_buf()];
    while let Some(directory) = queue.pop() {
        let Ok(entries) = std::fs::read_dir(&directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                queue.push(path.clone());
            }
            found.push(path.display().to_string());
        }
    }
    found.sort();
    found
}
