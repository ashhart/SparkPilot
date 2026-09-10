//! Exercise signed catalogue trust, fit reporting, unverified-import policy and path containment.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;
use std::time::Duration;

use axum::body::to_bytes;
use axum::http::{Method, Request, StatusCode};
use ed25519_dalek::SigningKey;
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey;
use rand::RngCore;
use serde_json::{Value, json};
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_models::catalogue::SignedCatalogue;
use spark_models::recipe::fixture::RecipeFixture;
use spark_models::verify::{CatalogueRoot, testkit};
use spark_telemetry::FakeSystemMonitor;
use sparkd::auth;
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::engine::{
    BackendError, ContainerRuntimeReport, EngineBackend, EngineImagePreparation, EngineInstance,
    EngineManager,
};
use sparkd::migration;
use sparkd::models::ModelInventory;
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use tower::ServiceExt;

const SEED: [u8; 32] = [19u8; 32];

struct InertEngineBackend(bool);

#[async_trait::async_trait]
impl EngineBackend for InertEngineBackend {
    async fn prepare(
        &self,
        _instance: &EngineInstance,
    ) -> Result<EngineImagePreparation, BackendError> {
        Err(BackendError("not used".into()))
    }

    async fn launch(&self, _instance: &EngineInstance) -> Result<u16, BackendError> {
        Err(BackendError("not used".into()))
    }

    async fn stop(&self, _instance: &EngineInstance, _force: bool) -> Result<(), BackendError> {
        Err(BackendError("not used".into()))
    }

    async fn reconcile_instance(
        &self,
        _instance_id: uuid::Uuid,
        _external_workload_id: Option<&str>,
    ) -> Result<(), BackendError> {
        Err(BackendError("not used".into()))
    }

    async fn is_running(&self, _instance: &EngineInstance) -> bool {
        self.0
    }

    async fn health(&self, _instance: &EngineInstance) -> Result<bool, BackendError> {
        Ok(self.0)
    }

    async fn list_model_names(
        &self,
        instance: &EngineInstance,
    ) -> Result<Vec<String>, BackendError> {
        Ok(if self.0 {
            vec![instance.served_name.clone()]
        } else {
            Vec::new()
        })
    }

    async fn probe_completion(&self, _instance: &EngineInstance) -> Result<(), BackendError> {
        Err(BackendError("not used".into()))
    }

    fn probe_container_runtime(&self) -> ContainerRuntimeReport {
        ContainerRuntimeReport::new("mock", true, None)
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
        let mut scalar = [0u8; 32];
        rand::rng().fill_bytes(&mut scalar);
        if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&scalar) {
            return key;
        }
    }
}

fn write_signed_catalogue(dir: &std::path::Path) -> (std::path::PathBuf, std::path::PathBuf) {
    let signing = SigningKey::from_bytes(&SEED);
    let mut recipe = RecipeFixture::example();
    testkit::sign_recipe(&mut recipe, &signing);
    let mut envelope = SignedCatalogue {
        recipes: vec![recipe.clone()],
        signature: spark_models::catalogue::CatalogueSignature {
            key_id: "catalogue-test".into(),
            algorithm: "ed25519".into(),
            value: String::new(),
        },
    };
    let canonical = envelope.canonical_entries().unwrap();
    envelope.signature.value = testkit::sign_bytes(&canonical, &signing);

    let catalogue_path = dir.join("catalogue.json");
    std::fs::write(
        &catalogue_path,
        serde_json::to_vec_pretty(&envelope).unwrap(),
    )
    .unwrap();
    // Root key as 32-byte verifying-key hex text (the loader's format).
    let root_path = dir.join("catalogue-root.pub");
    std::fs::write(&root_path, hex::encode(signing.verifying_key().to_bytes())).unwrap();
    (catalogue_path, root_path)
}

fn expanded_signed_catalogue_json() -> String {
    let signing = SigningKey::from_bytes(&SEED);
    let mut original = RecipeFixture::example();
    testkit::sign_recipe(&mut original, &signing);
    let mut added = RecipeFixture::example();
    added.metadata.id = "example/model-7b".into();
    added.metadata.display_name = "Example 7B".into();
    added.source.repository = "example/example-7b-instruct".into();
    added.engine.served_name = "example-7b".into();
    testkit::sign_recipe(&mut added, &signing);
    let mut envelope = SignedCatalogue {
        recipes: vec![original, added],
        signature: spark_models::catalogue::CatalogueSignature {
            key_id: "catalogue-test".into(),
            algorithm: "ed25519".into(),
            value: String::new(),
        },
    };
    envelope.signature.value =
        testkit::sign_bytes(&envelope.canonical_entries().unwrap(), &signing);
    serde_json::to_string(&envelope).unwrap()
}

fn signed_profile_update(mut change: impl FnMut(&mut spark_models::ModelRecipe)) -> String {
    let signing = SigningKey::from_bytes(&SEED);
    let mut recipe = RecipeFixture::example();
    recipe.metadata.revision = "2026-09-04.1".into();
    change(&mut recipe);
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
    serde_json::to_string(&envelope).unwrap()
}

fn additional_context_profile(recipe: &mut spark_models::ModelRecipe) {
    let mut profile = recipe.profiles[0].clone();
    profile.id = "context-1m".into();
    profile.display_name = "Long Context 1M".into();
    profile.max_model_length = 1_048_576;
    recipe.profiles.insert(0, profile);
    recipe.metadata.description = Some("Corrected model description.".into());
}

include!(
    "models/scenarios/profile_refresh_refuses_changed_artifacts_existing_profiles_and_launches.rs"
);

async fn apply_profile_refresh(peer: &TestPeer, candidate: &str) {
    let (_, preview) = send(
        peer,
        Method::POST,
        "/api/v1/catalogue/refresh/preview",
        json!({"candidate_json": candidate}),
    )
    .await;
    let preview = preview.unwrap();
    assert_eq!(preview["blockers"], json!([]), "{preview}");
    let (status, operation) = send(
        peer,
        Method::POST,
        "/api/v1/catalogue/refresh",
        json!({
            "candidate_json": candidate,
            "accepted_preview_digest": preview["preview_digest"],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED, "{operation:?}");
    let operation_id = operation.unwrap()["id"].as_str().unwrap().to_owned();
    for _ in 0..200 {
        let state: String = peer
            .state
            .database
            .as_ref()
            .unwrap()
            .lock()
            .query_row(
                "SELECT state FROM operations WHERE id = ?1",
                [&operation_id],
                |row| row.get(0),
            )
            .unwrap();
        if state == "succeeded" {
            return;
        }
        assert_ne!(state, "failed", "catalogue refresh failed");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    panic!("catalogue refresh did not finish");
}

include!(
    "models/scenarios/profile_refresh_keeps_active_engine_recipe_and_recovers_interrupted_materialization.rs"
);

include!(
    "models/scenarios/signed_profile_refresh_preserves_installed_artifacts_and_measurements.rs"
);

fn signed_catalogue_without_original_json() -> String {
    let signing = SigningKey::from_bytes(&SEED);
    let mut replacement = RecipeFixture::example();
    replacement.metadata.id = "example/model-7b".into();
    replacement.metadata.display_name = "Example 7B".into();
    replacement.source.repository = "example/example-7b-instruct".into();
    replacement.engine.served_name = "example-7b".into();
    testkit::sign_recipe(&mut replacement, &signing);
    let mut envelope = SignedCatalogue {
        recipes: vec![replacement],
        signature: spark_models::catalogue::CatalogueSignature {
            key_id: "catalogue-test".into(),
            algorithm: "ed25519".into(),
            value: String::new(),
        },
    };
    envelope.signature.value =
        testkit::sign_bytes(&envelope.canonical_entries().unwrap(), &signing);
    serde_json::to_string(&envelope).unwrap()
}

/// The environment production measures the fixture recipe in; a peak stored under any other is not evidence.
fn fixture_environment() -> String {
    sparkd::guard::recipe_environment(&RecipeFixture::example())
}

fn full_peer(allow_unverified: bool) -> TestPeer {
    build_peer(allow_unverified, true)
}

fn build_peer(allow_unverified: bool, wire_engine: bool) -> TestPeer {
    let dir = tempfile::tempdir().unwrap();
    let (catalogue_path, _root_path) = write_signed_catalogue(dir.path());
    let mut identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("models-test")
        .unwrap();
    identity.public.node_id = SIGNING_NODE_ID;

    let inventory = ModelInventory::from_catalogue_with_root(
        &catalogue_path,
        CatalogueRoot::from_seed(&SEED),
        allow_unverified,
    )
    .expect("verified catalogue loads");

    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    migration::migrate(&mut conn).unwrap();
    inventory
        .materialize(&conn)
        .expect("catalogue materialised");

    let device_key = key();
    let device_id = uuid::Uuid::new_v4();
    let spki = device_key
        .verifying_key()
        .to_public_key_der()
        .unwrap()
        .as_bytes()
        .to_vec();
    let presence_key = key();
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
        "owner",
        Some((&presence_spki, &sha256_hex(&presence_spki))),
    )
    .unwrap();

    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".into(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "models-test".into(),
        data_dir: dir.path().into(),
        advertise: false,
        tls: false,
    };
    let monitor = Arc::new(FakeSystemMonitor);
    let state = AppState::new(config, identity, monitor.clone(), Some(conn)).with_models(Arc::new(
        sparkd::models::ModelInventory {
            recipes: inventory.recipes.clone(),
            allow_unverified_import: inventory.allow_unverified_import,
        },
    ));
    let database = state.database.as_ref().expect("database").clone();
    let state = if wire_engine {
        let engine = Arc::new(EngineManager::new(
            Arc::new(InertEngineBackend(false)),
            state.jobs.clone(),
            state.events.clone(),
            state.identity.node_id().to_string(),
            monitor,
            database,
            dir.path().join("models"),
            Duration::ZERO,
            None,
        ));
        state.with_engine(engine)
    } else {
        state
    };
    let refresh = sparkd::catalogue_api::CatalogueRefreshService::new(
        catalogue_path,
        CatalogueRoot::from_seed(&SEED),
        state.models.as_ref().expect("live models").clone(),
        state.database.as_ref().expect("database").clone(),
    )
    .expect("catalogue refresh configured");
    let state = state.with_catalogue_refresh(Arc::new(refresh));
    TestPeer {
        state,
        device_key,
        presence_key,
        device_id,
        _directory: dir,
    }
}

/// Omit the engine deliberately so the fixture cannot claim known residency or confident fit.
fn peer_without_engine() -> TestPeer {
    build_peer(false, false)
}

fn signed_request(
    peer: &TestPeer,
    method: Method,
    path: &str,
    body: &[u8],
) -> Request<axum::body::Body> {
    signed_request_with_key(peer, method, path, body, uuid::Uuid::new_v4())
}

fn signed_request_with_key(
    peer: &TestPeer,
    method: Method,
    path: &str,
    body: &[u8],
    idempotency_key: uuid::Uuid,
) -> Request<axum::body::Body> {
    let mut nonce = [0u8; 24];
    rand::rng().fill_bytes(&mut nonce);
    let now = time::OffsetDateTime::now_utc();
    let timestamp = now
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let digest = sha256_hex(body);
    let canonical = auth::canonical(
        method.as_str(),
        path,
        &timestamp,
        &base64url_encode(&nonce),
        &digest,
        &peer.device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = peer.device_key.sign(canonical.as_bytes());
    let expires_at = (now + time::Duration::seconds(45))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let presence_canonical = spark_contracts::user_presence_canonical(
        method.as_str(),
        path,
        &timestamp,
        &base64url_encode(&nonce),
        &digest,
        &peer.device_id,
        &expires_at,
        &SIGNING_NODE_ID,
    );
    let presence_signature: p256::ecdsa::Signature =
        peer.presence_key.sign(presence_canonical.as_bytes());
    let presence = spark_contracts::UserPresenceHeader {
        version: spark_contracts::USER_PRESENCE_PROOF_VERSION,
        expires_at,
        signature: base64url_encode(&presence_signature.to_bytes()),
    };
    let builder = Request::builder()
        .method(method)
        .uri(path)
        .header("idempotency-key", idempotency_key.to_string())
        .header(auth::HEADER_DEVICE_ID, peer.device_id.to_string())
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header(auth::HEADER_TIMESTAMP, timestamp)
        .header(auth::HEADER_NONCE, base64url_encode(&nonce))
        .header(auth::HEADER_CONTENT_SHA256, digest)
        .header(
            auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        )
        .header(
            sparkd::user_presence::HEADER_USER_PRESENCE,
            base64url_encode(&serde_json::to_vec(&presence).unwrap()),
        );
    if body.is_empty() {
        builder.body(axum::body::Body::empty()).unwrap()
    } else {
        builder
            .header("content-type", "application/json")
            .body(axum::body::Body::from(body.to_vec()))
            .unwrap()
    }
}

async fn send(
    peer: &TestPeer,
    method: Method,
    path: &str,
    body: Value,
) -> (StatusCode, Option<Value>) {
    let bytes = serde_json::to_vec(&body).unwrap();
    let response = router(peer.state.clone())
        .oneshot(signed_request(
            peer,
            method,
            path,
            if body.is_null() { &[] } else { &bytes },
        ))
        .await
        .unwrap();
    let status = response.status();
    let raw = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    (status, serde_json::from_slice(&raw).ok())
}

async fn send_with_key(
    peer: &TestPeer,
    method: Method,
    path: &str,
    body: Value,
    idempotency_key: uuid::Uuid,
) -> (StatusCode, Option<Value>) {
    let bytes = serde_json::to_vec(&body).unwrap();
    let response = router(peer.state.clone())
        .oneshot(signed_request_with_key(
            peer,
            method,
            path,
            if body.is_null() { &[] } else { &bytes },
            idempotency_key,
        ))
        .await
        .unwrap();
    let status = response.status();
    let raw = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    (status, serde_json::from_slice(&raw).ok())
}

async fn get(peer: &TestPeer, path: &str) -> (StatusCode, Option<Value>) {
    let response = router(peer.state.clone())
        .oneshot(signed_request(peer, Method::GET, path, &[]))
        .await
        .unwrap();
    let status = response.status();
    let raw = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    (status, serde_json::from_slice(&raw).ok())
}

include!("models/scenarios/catalogue_lists_verified_models_with_fit.rs");

include!("models/scenarios/catalogue_refresh_status_is_owner_visible_and_device_local.rs");

include!("models/scenarios/signed_catalogue_refresh_is_presence_gated_durable_and_hot_reloaded.rs");

include!("models/scenarios/refresh_rejects_tampering_and_blocks_dropping_an_installed_model.rs");

include!(
    "models/scenarios/failed_catalogue_persistence_restores_the_previous_snapshot_and_live_inventory.rs"
);

include!("models/scenarios/model_detail_and_remove_are_consistent.rs");

include!("models/scenarios/traversal_ids_are_handled_as_ids_not_paths.rs");

include!("models/scenarios/tampered_catalogue_is_rejected_at_load.rs");

include!("models/scenarios/unpinned_image_recipe_is_rejected_even_if_signed.rs");

include!("models/scenarios/unverified_import_is_gated.rs");

include!("models/scenarios/unverified_import_cannot_break_an_installed_model_by_id_collision.rs");

#[allow(dead_code)]
fn _root_parses() {
    // Ensure the CatalogueRoot keyid convention used by tests is accepted.
    let _ = CatalogueRoot::from_seed(&SEED);
}

include!("models/scenarios/fit_is_unknown_when_residency_cannot_be_observed.rs");

include!("models/scenarios/the_model_surface_reports_stored_profile_safety_and_measured_peak.rs");

include!("models/scenarios/install_preview_keeps_runtime_responsive.rs");
