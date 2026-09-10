use super::install_worker::DbProgressSink;
use super::operations::may_view_operation;
use super::*;
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey as _;
use std::sync::atomic::{AtomicUsize, Ordering};

struct CredentialRemovingResolver {
    calls: AtomicUsize,
    credential_path: std::path::PathBuf,
    database: Arc<parking_lot::Mutex<rusqlite::Connection>>,
    credential_id: uuid::Uuid,
}

impl crate::download::SourceResolver for CredentialRemovingResolver {
    fn resolve(
        &self,
        _recipe: &spark_models::ModelRecipe,
    ) -> Result<Vec<spark_models::RemoteFile>, String> {
        Ok(Vec::new())
    }

    fn resolve_with_credential(
        &self,
        _recipe: &spark_models::ModelRecipe,
        _credential_path: Option<&std::path::Path>,
    ) -> Result<Vec<spark_models::RemoteFile>, String> {
        if self.calls.fetch_add(1, Ordering::SeqCst) == 1 {
            std::fs::remove_file(&self.credential_path).map_err(|error| error.to_string())?;
            self.database
                .lock()
                .execute(
                    "UPDATE provider_credentials SET revoked_at = ?1 WHERE id = ?2",
                    rusqlite::params![crate::store::now_iso8601(), self.credential_id.to_string()],
                )
                .map_err(|error| error.to_string())?;
        }
        Ok(Vec::new())
    }
}

struct NoFileSource;

struct EmptyResolver;

impl crate::download::SourceResolver for EmptyResolver {
    fn resolve(
        &self,
        _recipe: &spark_models::ModelRecipe,
    ) -> Result<Vec<spark_models::RemoteFile>, String> {
        Ok(Vec::new())
    }
}

impl crate::download::FileSource for NoFileSource {
    fn fetch(
        &self,
        _recipe: &spark_models::ModelRecipe,
        _file: &spark_models::RemoteFile,
        _range: Option<(u64, usize)>,
    ) -> Result<Vec<u8>, String> {
        Err("no files".into())
    }
}

#[derive(Clone, Copy)]
enum ImageReadinessReply {
    Ready,
    Rejected,
}

fn image_readiness_responder(
    socket: &std::path::Path,
    reply: ImageReadinessReply,
) -> (
    crate::privd::PrivilegedClient,
    std::sync::mpsc::Receiver<PrivilegedOperation>,
) {
    let listener = std::os::unix::net::UnixListener::bind(socket).unwrap();
    let (observed_tx, observed_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let operation = spark_privd::protocol::read_request(&mut stream).unwrap();
        observed_tx.send(operation.clone()).unwrap();
        let request_id = operation.request_id();
        let response = match (&operation, reply) {
            (
                PrivilegedOperation::EnsureEngineImage { image_digest, .. },
                ImageReadinessReply::Ready,
            ) => PrivilegedResponse {
                request_id,
                accepted: true,
                code: "image_ready".into(),
                message: "ready".into(),
                details: json!({
                    "image_digest": image_digest,
                    "pulled": false,
                }),
            },
            (_, ImageReadinessReply::Rejected) => {
                PrivilegedResponse::rejected(request_id, "image_pull_failed", "image pull failed")
            }
            _ => PrivilegedResponse::rejected(
                request_id,
                "unexpected_operation",
                "unexpected operation",
            ),
        };
        spark_privd::protocol::write_response(&mut stream, &response).unwrap();
    });
    (crate::privd::PrivilegedClient::new(socket), observed_rx)
}

fn image_install_state(
    directory: &std::path::Path,
    privileged: crate::privd::PrivilegedClient,
) -> (AppState, spark_models::ModelRecipe, uuid::Uuid) {
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut connection).unwrap();
    let recipe = spark_models::recipe::fixture::RecipeFixture::example();
    crate::store::upsert_catalogue_model(&connection, &recipe).unwrap();
    let actor = uuid::Uuid::new_v4();
    crate::store::insert_device(
        &connection,
        &actor,
        "image readiness owner",
        "ios",
        b"image-readiness-public-key",
        &format!("image-readiness-{actor}"),
        "owner",
    )
    .unwrap();
    let state = AppState::new(
        crate::state::RuntimeConfig {
            api_major: 1,
            runtime_version: "image-readiness-test".into(),
            listen: "127.0.0.1:0".parse().unwrap(),
            node_name: "image-readiness-test".into(),
            data_dir: directory.to_path_buf(),
            advertise: false,
            tls: false,
        },
        spark_core::identity::NodeIdentity::generate("image-readiness-test"),
        Arc::new(spark_telemetry::FakeSystemMonitor),
        Some(connection),
    )
    .with_disk_reserve(0)
    .with_models(Arc::new(crate::models::ModelInventory {
        recipes: vec![recipe.clone()],
        allow_unverified_import: false,
    }))
    .with_download(crate::download::DownloadCoordinator {
        resolver: Box::new(EmptyResolver),
        source: Box::new(NoFileSource),
    })
    .with_privileged_socket(privileged);
    let operation_id = state
        .jobs
        .create(
            &state.database.as_ref().unwrap().lock(),
            "model.install",
            actor,
            Some(recipe.id()),
            &json!({ "model_id": recipe.id() }).to_string(),
        )
        .unwrap();
    (state, recipe, operation_id)
}

fn wait_for_image_install(
    state: &AppState,
    operation_id: uuid::Uuid,
) -> crate::store::OperationRow {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let row = state
            .jobs
            .get(&state.database.as_ref().unwrap().lock(), operation_id)
            .unwrap()
            .unwrap();
        if matches!(row.state.as_str(), "succeeded" | "failed" | "cancelled") {
            return row;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "model install did not become terminal"
        );
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}

include!("tests/scenarios/image_readiness_requires_the_exact_typed_response_shape.rs");

include!("tests/scenarios/install_worker_prepares_the_signed_engine_image_before_installing.rs");

include!(
    "tests/scenarios/rejected_engine_image_fails_the_operation_without_installing_the_model.rs"
);

fn credential_state(directory: &std::path::Path, device_id: uuid::Uuid) -> AppState {
    use spark_core::identity::{FileIdentityStore, IdentityStore};

    let identity = FileIdentityStore::new(directory.join("identity"))
        .load_or_create("credential-test")
        .unwrap();
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut connection).unwrap();
    let presence_key = credential_presence_key();
    let presence_spki = presence_key.verifying_key().to_public_key_der().unwrap();
    crate::store::insert_device_with_presence_key(
        &connection,
        &device_id,
        "credential owner",
        "macos",
        b"test-public-key",
        "test-key-fingerprint",
        "owner",
        Some((presence_spki.as_bytes(), "test-presence-key-fingerprint")),
    )
    .unwrap();
    let config = crate::state::RuntimeConfig {
        api_major: 1,
        runtime_version: "test".into(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "credential-test".into(),
        data_dir: directory.to_path_buf(),
        advertise: false,
        tls: false,
    };
    AppState::new(
        config,
        identity,
        std::sync::Arc::new(spark_telemetry::FakeSystemMonitor),
        None,
    )
    .with_database(std::sync::Arc::new(parking_lot::Mutex::new(connection)))
}

fn owner() -> Principal {
    Principal {
        device_id: uuid::Uuid::new_v4(),
        role: "owner".into(),
        access_authentication: crate::auth::AccessAuthentication::DeviceSignature,
        user_presence: None,
    }
}

fn principal_with(role: &str, device_id: uuid::Uuid) -> Principal {
    Principal {
        device_id,
        role: role.into(),
        access_authentication: crate::auth::AccessAuthentication::DeviceSignature,
        user_presence: None,
    }
}

fn operation_owned_by(actor: uuid::Uuid) -> crate::store::OperationRow {
    crate::store::OperationRow {
        id: uuid::Uuid::new_v4(),
        kind: "model.install".into(),
        state: "running".into(),
        actor_device_id: actor,
        resource_id: None,
        progress: None,
        stage: None,
        created_at: String::new(),
        updated_at: String::new(),
        started_at: None,
        completed_at: None,
        error_code: None,
        result: None,
        cancellable: true,
    }
}

include!("tests/scenarios/operation_visibility_follows_actor_and_role.rs");

fn credential_presence_key() -> p256::ecdsa::SigningKey {
    p256::ecdsa::SigningKey::from_slice(&[42; 32]).unwrap()
}

fn credential_presence(
    principal: &Principal,
    method: &str,
    path: &str,
    content_sha256: &str,
) -> (AuthenticatedRequest, HeaderMap) {
    credential_presence_expiring(principal, method, path, content_sha256, 45)
}

fn credential_presence_expiring(
    principal: &Principal,
    method: &str,
    path: &str,
    content_sha256: &str,
    expires_in_seconds: i64,
) -> (AuthenticatedRequest, HeaderMap) {
    let now = time::OffsetDateTime::now_utc();
    let timestamp = now
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let expires_at = (now + time::Duration::seconds(expires_in_seconds))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let request = AuthenticatedRequest {
        node_id: uuid::Uuid::from_u128(2),
        method: method.into(),
        path_and_query: path.into(),
        timestamp,
        nonce: "credential-test-nonce".into(),
        content_sha256: content_sha256.into(),
        device_id: principal.device_id,
    };
    let canonical = spark_contracts::user_presence_canonical(
        &request.method,
        &request.path_and_query,
        &request.timestamp,
        &request.nonce,
        &request.content_sha256,
        &request.device_id,
        &expires_at,
        &request.node_id,
    );
    let signature: p256::ecdsa::Signature = credential_presence_key().sign(canonical.as_bytes());
    let proof = spark_contracts::UserPresenceHeader {
        version: spark_contracts::USER_PRESENCE_PROOF_VERSION,
        expires_at,
        signature: crate::crypto::base64url_encode(&signature.to_bytes()),
    };
    let mut headers = HeaderMap::new();
    headers.insert(
        crate::user_presence::HEADER_USER_PRESENCE,
        crate::crypto::base64url_encode(&serde_json::to_vec(&proof).unwrap())
            .parse()
            .unwrap(),
    );
    (request, headers)
}

/// Seed a migrated model, file and live operation lease for progress-sink tests.
fn seeded_sink_fixture() -> (
    Arc<parking_lot::Mutex<rusqlite::Connection>>,
    crate::jobs::JobService,
    uuid::Uuid,
    spark_models::ModelRecipe,
) {
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut conn).unwrap();
    let recipe = spark_models::recipe::fixture::RecipeFixture::example();
    crate::store::upsert_catalogue_model(&conn, &recipe).unwrap();
    crate::store::upsert_model_file(
        &conn,
        recipe.id(),
        &spark_models::RemoteFile {
            relative_path: "weights.bin".into(),
            size_bytes: 100,
            sha256: "0".repeat(64),
        },
    )
    .unwrap();
    let actor = uuid::Uuid::new_v4();
    crate::store::insert_device(
        &conn,
        &actor,
        "sink test",
        "macos",
        &[1, 2, 3],
        &format!("sink-{actor}"),
        "owner",
    )
    .unwrap();
    let jobs = crate::jobs::JobService::new();
    let operation_id = jobs
        .create(&conn, "model.install", actor, None, "{}")
        .unwrap();
    (
        Arc::new(parking_lot::Mutex::new(conn)),
        jobs,
        operation_id,
        recipe,
    )
}

include!("tests/scenarios/download_progress_is_persisted_before_live_fanout.rs");

include!(
    "tests/scenarios/a_stage_write_from_the_progress_sink_does_not_deadlock_on_the_database.rs"
);

include!("tests/scenarios/credential_add_and_revoke_replay_the_exact_first_response.rs");

include!(
    "tests/scenarios/credential_mutation_requires_fresh_presence_before_storing_the_secret.rs"
);

include!("tests/scenarios/expired_presence_cannot_add_a_credential.rs");

include!("tests/scenarios/credential_list_is_role_gated_and_contains_no_secret_fields.rs");

include!("tests/scenarios/ordinary_role_cannot_add_a_provider_credential.rs");

include!("tests/scenarios/install_start_failure_replaces_the_replay_and_fails_the_operation.rs");
