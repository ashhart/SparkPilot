const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

use std::sync::Arc;

use axum::body::to_bytes;
use axum::http::{Method, Request, StatusCode};
use p256::ecdsa::signature::Signer as _;
use p256::pkcs8::EncodePublicKey as _;
use serde_json::json;
use spark_core::identity::{FileIdentityStore, IdentityStore, PublicIdentity};
use spark_project_runner::{CommandGit, FakeContainerBoundary, ScriptedPtyRunner};
use sparkd::build::{BuildService, CLAIM_LEASE_SECONDS, WORKER_LIVENESS_SECONDS};
use sparkd::build_protocol::{
    BuildArtifactEvidence, BuildRequirements, BuildResultEvidence, MAX_ARTIFACT_BYTES,
    MAX_ARTIFACT_TOTAL_BYTES, MAX_ARTIFACTS, PROTOCOL_VERSION, SignedBuildResult,
};
use sparkd::clock::ManualUtcClock;
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::project::{ProjectManager, ProjectView};
use sparkd::route::router;
use sparkd::state::{AppState, RuntimeConfig};
use sparkd::{auth, migration, store};
use tower::ServiceExt as _;
use uuid::Uuid;

const COMMIT: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const SOURCE: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

struct Harness {
    service: Arc<BuildService>,
    clock: Arc<ManualUtcClock>,
    public_identity: PublicIdentity,
    project: ProjectView,
    owner: Uuid,
    state: AppState,
    _directory: tempfile::TempDir,
}

fn harness() -> Harness {
    let directory = tempfile::tempdir().unwrap();
    let mut identity = FileIdentityStore::new(directory.path().join("identity"))
        .load_or_create("build-test")
        .unwrap();
    identity.public.node_id = SIGNING_NODE_ID;
    let public_identity = identity.public.clone();
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    migration::migrate(&mut connection).unwrap();
    let database = Arc::new(parking_lot::Mutex::new(connection));
    let clock = Arc::new(ManualUtcClock::new(
        time::OffsetDateTime::parse(
            "2026-09-01T12:00:00Z",
            &time::format_description::well_known::Rfc3339,
        )
        .unwrap(),
    ));
    let state = AppState::new_with_clock(
        RuntimeConfig {
            api_major: 1,
            runtime_version: "0.1.0".into(),
            listen: "127.0.0.1:0".parse().unwrap(),
            node_name: "build-test".into(),
            data_dir: directory.path().into(),
            advertise: false,
            tls: false,
        },
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        None,
        clock.clone(),
    )
    .with_database(database.clone());
    let projects = Arc::new(ProjectManager::new(
        Arc::new(CommandGit::new("git")),
        Arc::new(FakeContainerBoundary::default()),
        Arc::new(ScriptedPtyRunner::default()),
        database.clone(),
        state.jobs.clone(),
        state.events.clone(),
        state.identity.node_id().to_string(),
        directory.path().join("projects"),
        directory.path().join("worktrees"),
    ));
    let service = Arc::new(BuildService::new(
        projects.clone(),
        state.jobs.clone(),
        state.events.clone(),
        state.identity.clone(),
        directory.path().join("build-work"),
    ));
    let owner = Uuid::new_v4();
    let project_id = Uuid::new_v4();
    {
        let connection = database.lock();
        let owner_key = p256::ecdsa::SigningKey::from_slice(&[3; 32]).unwrap();
        store::insert_device(
            &connection,
            &owner,
            "Owner Mac",
            "macos",
            &spki(&owner_key),
            "owner-test-fingerprint",
            "owner",
        )
        .unwrap();
        store::insert_project(
            &connection,
            &project_id,
            "App",
            &owner,
            "/tmp/app",
            Some("https://example.invalid/app.git"),
        )
        .unwrap();
        store::insert_project_member(&connection, &project_id, &owner, "admin").unwrap();
    }
    let state = state.with_projects(projects).with_builds(service.clone());
    Harness {
        service,
        clock,
        public_identity,
        project: ProjectView {
            id: project_id,
            name: "App".into(),
            state: "ready".into(),
            root_path: directory.path().join("project"),
            repository_url: Some("https://example.invalid/app.git".into()),
            default_branch: Some("main".into()),
            created_at: "2026-09-01T12:00:00Z".into(),
            updated_at: "2026-09-01T12:00:00Z".into(),
        },
        owner,
        state,
        _directory: directory,
    }
}

fn capabilities(max: u64) -> serde_json::Value {
    json!({"architectures":["arm64"],"sdk_versions":["macosx"],"simulators":["iPhone 17"],"signing_available":true,"max_concurrent_jobs":max})
}

fn submit(harness: &Harness, requirements: &BuildRequirements) -> Uuid {
    harness
        .service
        .submit_build(
            Uuid::new_v4(),
            &harness.project,
            COMMIT,
            SOURCE,
            "SparkPilot",
            "Release",
            "generic/platform=macOS",
            vec!["build".into(), "test".into()],
            600,
            requirements,
            &harness.owner,
        )
        .unwrap()
}

fn signed_result(
    key: &p256::ecdsa::SigningKey,
    claim: &sparkd::build_protocol::BuildClaim,
    completed_at: &str,
) -> SignedBuildResult {
    let output = "** TEST SUCCEEDED **".to_owned();
    let evidence = BuildResultEvidence {
        protocol: PROTOCOL_VERSION.into(),
        build_id: claim.recipe.payload.build_id,
        worker_id: claim.recipe.payload.worker_id,
        claim_generation: claim.recipe.payload.claim_generation,
        project_id: claim.recipe.payload.project_id,
        commit: claim.recipe.payload.commit.clone(),
        source_sha256: claim.recipe.payload.source_sha256.clone(),
        recipe_sha256: claim.recipe_sha256.clone(),
        exit_state: "succeeded".into(),
        started_at: claim.recipe.payload.issued_at.clone(),
        completed_at: completed_at.into(),
        output_sha256: sha256_hex(output.as_bytes()),
        output,
        test_failures: vec![],
        diagnostics: vec![],
        artifacts: vec![],
    };
    let signature: p256::ecdsa::Signature =
        key.sign(&sparkd::build_protocol::canonical_json(&evidence).unwrap());
    SignedBuildResult {
        evidence,
        worker_signature: base64url_encode(signature.to_bytes().as_ref()),
    }
}

fn spki(key: &p256::ecdsa::SigningKey) -> Vec<u8> {
    key.verifying_key()
        .to_public_key_der()
        .unwrap()
        .as_bytes()
        .to_vec()
}

fn signed_get(
    key: &p256::ecdsa::SigningKey,
    device_id: Uuid,
    path: &str,
) -> Request<axum::body::Body> {
    let timestamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let nonce = base64url_encode(Uuid::new_v4().as_bytes());
    let digest = sha256_hex(b"");
    let canonical = auth::canonical(
        "GET",
        path,
        &timestamp,
        &nonce,
        &digest,
        &device_id,
        &SIGNING_NODE_ID,
    );
    let signature: p256::ecdsa::Signature = key.sign(canonical.as_bytes());
    Request::builder()
        .method(Method::GET)
        .uri(path)
        .header(auth::HEADER_DEVICE_ID, device_id.to_string())
        .header("x-spark-node-id", SIGNING_NODE_ID.to_string())
        .header(auth::HEADER_TIMESTAMP, timestamp)
        .header(auth::HEADER_NONCE, nonce)
        .header(auth::HEADER_CONTENT_SHA256, digest)
        .header(
            auth::HEADER_SIGNATURE,
            base64url_encode(&signature.to_bytes()),
        )
        .body(axum::body::Body::empty())
        .unwrap()
}

include!("build_flow/scenarios/submission_requires_immutable_commit_and_source_digest.rs");

include!(
    "build_flow/scenarios/stable_worker_reregistration_refreshes_but_never_changes_its_device.rs"
);

include!("build_flow/scenarios/claim_is_acl_capability_concurrency_and_recipe_bound.rs");

include!(
    "build_flow/scenarios/signed_result_rejects_tampering_wrong_worker_and_accepts_exact_replay.rs"
);

include!("build_flow/scenarios/expiry_requeues_and_late_result_is_refused.rs");

include!("build_flow/scenarios/artifact_hashes_and_signed_result_evidence_are_verified.rs");

include!(
    "build_flow/scenarios/claim_retry_is_exact_without_persisting_secrets_in_generic_idempotency.rs"
);

include!("build_flow/scenarios/generation_blocks_same_worker_aba_and_expiry_removes_artifacts.rs");

include!("build_flow/scenarios/cancellation_acknowledgement_removes_generation_artifacts.rs");

include!(
    "build_flow/scenarios/result_artifact_evidence_is_bijective_and_download_is_authorized_and_digest_checked.rs"
);

include!("build_flow/scenarios/expired_heartbeat_is_projected_offline.rs");

include!("build_flow/scenarios/production_does_not_expose_a_linux_xcode_runner.rs");

include!("build_flow/scenarios/the_build_lifecycle_is_announced_on_the_event_stream.rs");

include!("build_flow/scenarios/a_worker_that_stops_beating_is_announced_offline_once.rs");

include!("build_flow/scenarios/a_submitted_build_announces_its_operation.rs");
