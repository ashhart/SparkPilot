//! Verify owner presence, exact unsafe-state preview binding, durable audit and idempotent retry for profile reenable.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;

use axum::body::to_bytes;
use axum::http::{Method, Request, StatusCode};
use ed25519_dalek::SigningKey;
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey as _;
use rand::RngCore;
use rusqlite::Connection;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_models::catalogue::SignedCatalogue;
use spark_models::recipe::fixture::RecipeFixture;
use spark_models::verify::{CatalogueRoot, testkit};
use spark_telemetry::{FakeSystemMonitor, MemoryPolicy, MemorySignals, MemorySource};
use sparkd::auth;
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::events::EventBus;
use sparkd::guard::{self, MemoryGuardService, NoEngine};
use sparkd::migration;
use sparkd::models::ModelInventory;
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

const SEED: [u8; 32] = [23u8; 32];
const MODEL: &str = "example/model-32b";
const MODEL_PATH: &str = "example%2Fmodel-32b";
const PROFILE: &str = "balanced-16k";
const OTHER_PROFILE: &str = "compact-8k";
const GIB: u64 = 1024 * 1024 * 1024;

struct CalmSource;

impl MemorySource for CalmSource {
    fn signals(&self) -> MemorySignals {
        MemorySignals::calm(128 * GIB)
    }
}

struct TestPeer {
    state: AppState,
    device_key: p256::ecdsa::SigningKey,
    presence_key: p256::ecdsa::SigningKey,
    device_id: uuid::Uuid,
    _directory: tempfile::TempDir,
}

fn key() -> p256::ecdsa::SigningKey {
    loop {
        let mut scalar = [0; 32];
        rand::rng().fill_bytes(&mut scalar);
        if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&scalar) {
            return key;
        }
    }
}

fn write_signed_catalogue(dir: &std::path::Path) -> std::path::PathBuf {
    let signing = SigningKey::from_bytes(&SEED);
    let mut recipe = RecipeFixture::example();
    // Add a second valid signed-recipe profile so cross-profile tests reach digest binding rather than unknown-profile refusal.
    let mut second = recipe.profiles[0].clone();
    second.id = OTHER_PROFILE.into();
    recipe.profiles.push(second);
    testkit::sign_recipe(&mut recipe, &signing);
    let mut envelope = SignedCatalogue {
        recipes: vec![recipe],
        signature: spark_models::catalogue::CatalogueSignature {
            key_id: "catalogue-test".into(),
            algorithm: "ed25519".into(),
            value: String::new(),
        },
    };
    envelope.signature.value =
        testkit::sign_bytes(&envelope.canonical_entries().unwrap(), &signing);
    let path = dir.join("catalogue.json");
    std::fs::write(&path, serde_json::to_vec(&envelope).unwrap()).unwrap();
    path
}

fn peer(role: &str) -> TestPeer {
    let dir = tempfile::tempdir().unwrap();
    let catalogue_path = write_signed_catalogue(dir.path());
    let mut identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("profile-test")
        .unwrap();
    identity.public.node_id = SIGNING_NODE_ID;
    let inventory = ModelInventory::from_catalogue_with_root(
        &catalogue_path,
        CatalogueRoot::from_seed(&SEED),
        false,
    )
    .expect("verified catalogue loads");

    let mut conn = Connection::open_in_memory().unwrap();
    migration::migrate(&mut conn).unwrap();
    inventory
        .materialize(&conn)
        .expect("catalogue materialised");

    let device_key = key();
    let presence_key = key();
    let device_id = uuid::Uuid::new_v4();
    let spki = device_key
        .verifying_key()
        .to_public_key_der()
        .unwrap()
        .as_bytes()
        .to_vec();
    let presence_spki = presence_key
        .verifying_key()
        .to_public_key_der()
        .unwrap()
        .as_bytes()
        .to_vec();
    sparkd::store::insert_device_with_presence_key(
        &conn,
        &device_id,
        "test client",
        "macos",
        &spki,
        &sha256_hex(&spki),
        role,
        Some((&presence_spki, &sha256_hex(&presence_spki))),
    )
    .unwrap();

    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".into(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "profile-test".into(),
        data_dir: dir.path().into(),
        advertise: false,
        tls: false,
    };
    let state = AppState::new(config, identity, Arc::new(FakeSystemMonitor), Some(conn))
        .with_models(Arc::new(ModelInventory {
            recipes: inventory.recipes.clone(),
            allow_unverified_import: inventory.allow_unverified_import,
        }));
    let database = state.database.as_ref().expect("database").clone();
    let state = state.with_guard(Arc::new(MemoryGuardService::with_database(
        MemoryPolicy::default(),
        Arc::new(CalmSource),
        Arc::new(NoEngine),
        EventBus::new(),
        database,
    )));
    TestPeer {
        state,
        device_key,
        presence_key,
        device_id,
        _directory: dir,
    }
}

/// The environment production measures the fixture recipe in; a peak stored under any other is not evidence.
fn fixture_environment() -> String {
    sparkd::guard::recipe_environment(&RecipeFixture::example())
}

/// Put the profile into the state an owner would be reviewing.
fn disable_profile(peer: &TestPeer) {
    let conn = peer.state.database.as_ref().unwrap().lock();
    guard::record_profile_peak(&conn, MODEL, PROFILE, 61 * GIB, &fixture_environment()).unwrap();
    guard::mark_profile_unsafe(&conn, MODEL, PROFILE, "MEMORY_PRESSURE_CRITICAL").unwrap();
}

fn signed_request(
    peer: &TestPeer,
    path: &str,
    body: &[u8],
    idempotency_key: uuid::Uuid,
    include_presence: bool,
) -> Request<axum::body::Body> {
    let mut nonce = [0; 24];
    rand::rng().fill_bytes(&mut nonce);
    let nonce = base64url_encode(&nonce);
    let now = time::OffsetDateTime::now_utc();
    let timestamp = now
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let content_sha256 = sha256_hex(body);
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
    let mut builder = Request::builder()
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
            .unwrap();
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
        builder = builder.header(
            sparkd::user_presence::HEADER_USER_PRESENCE,
            base64url_encode(&serde_json::to_vec(&proof).unwrap()),
        );
    }
    builder.body(axum::body::Body::from(body.to_vec())).unwrap()
}

async fn send(peer: &TestPeer, request: Request<axum::body::Body>) -> (StatusCode, Value) {
    let response = router(peer.state.clone()).oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

fn preview_path(model: &str, profile: &str) -> String {
    format!("/api/v1/models/{model}/profiles/{profile}/re-enable/preview")
}

fn apply_path(model: &str, profile: &str) -> String {
    format!("/api/v1/models/{model}/profiles/{profile}/re-enable")
}

async fn issue_preview(peer: &TestPeer) -> Value {
    let (status, body) = send(
        peer,
        signed_request(
            peer,
            &preview_path(MODEL_PATH, PROFILE),
            b"",
            uuid::Uuid::new_v4(),
            false,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "preview refused: {body}");
    body
}

fn is_unsafe(peer: &TestPeer) -> bool {
    is_unsafe_profile(peer, PROFILE)
}

fn is_unsafe_profile(peer: &TestPeer, profile: &str) -> bool {
    let conn = peer.state.database.as_ref().unwrap().lock();
    guard::profile_is_unsafe(&conn, MODEL, profile).unwrap()
}

async fn await_operation(peer: &TestPeer, operation_id: &str) {
    for _ in 0..200 {
        {
            let conn = peer.state.database.as_ref().unwrap().lock();
            let state: Option<String> = conn
                .query_row(
                    "SELECT state FROM operations WHERE id = ?1",
                    [operation_id],
                    |row| row.get(0),
                )
                .ok();
            if matches!(state.as_deref(), Some("succeeded" | "failed")) {
                return;
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    panic!("operation {operation_id} never reached a terminal state");
}

include!(
    "profile_reenable/scenarios/the_preview_reports_the_recorded_failure_the_owner_is_reviewing.rs"
);

include!("profile_reenable/scenarios/the_preview_decodes_through_the_generated_contract_types.rs");

include!(
    "profile_reenable/scenarios/a_safe_profile_is_blocked_because_there_is_nothing_to_review.rs"
);

include!("profile_reenable/scenarios/an_owner_with_presence_re_enables_the_reviewed_profile.rs");

include!(
    "profile_reenable/scenarios/a_digest_reviewed_for_one_profile_cannot_re_enable_another.rs"
);

include!(
    "profile_reenable/scenarios/a_stale_review_is_refused_after_the_recorded_failure_changes.rs"
);

include!("profile_reenable/scenarios/a_blocked_review_cannot_be_applied.rs");

include!("profile_reenable/scenarios/re_enabling_requires_fresh_user_presence.rs");

include!("profile_reenable/scenarios/an_administrator_cannot_re_enable_a_profile.rs");

include!("profile_reenable/scenarios/a_retried_re_enable_returns_the_first_operation.rs");

include!("profile_reenable/scenarios/an_unknown_profile_is_refused_before_any_review_is_issued.rs");

include!("profile_reenable/scenarios/the_capability_flag_advertises_the_route.rs");
