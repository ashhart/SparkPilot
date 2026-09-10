//! Exercise signed cluster creation, compatibility/link/collective validation, health, dissolve and launch-plan behavior.

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
use spark_privd::protocol::ClusterLinkPhase;
use sparkd::auth;
use sparkd::clock::ManualUtcClock;
use sparkd::cluster::{
    self, ClusterError, CollectiveOutcome, CollectiveTesting, DistributedLaunchPlan, LinkProbing,
    LinkReport, NoCollectiveTest, NoLinkProbe,
};
use sparkd::cluster_coordination::{
    ClusterCoordinationService, ClusterLinkControl, ClusterLinkProof, ClusterProposal,
    CoordinationError, DistributedExecutionSpec, DistributedRuntimeControl, NoDistributedRuntime,
};
use sparkd::crypto::{base64url_encode, sha256_hex};
use sparkd::fabric::{FabricPortStatus, FabricStatus, FabricStatusProvider};
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

fn signed_request(
    client: &TestClient,
    method: &str,
    path: &str,
    body: Option<&Value>,
) -> Request<axum::body::Body> {
    let presence_path = (method == "POST"
        && matches!(path, "/api/v1/cluster/create" | "/api/v1/cluster/validate"))
    .then_some(path);
    signed_request_with_options(
        client,
        method,
        path,
        body,
        uuid::Uuid::new_v4(),
        presence_path,
    )
}

fn signed_request_with_options(
    client: &TestClient,
    method: &str,
    path: &str,
    body: Option<&Value>,
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

struct ScriptedLink {
    report: LinkReport,
    fail: bool,
}

impl LinkProbing for ScriptedLink {
    fn probe(&self) -> Result<LinkReport, ClusterError> {
        if self.fail {
            Err(ClusterError::LinkUnhealthy(self.report.interface.clone()))
        } else {
            Ok(self.report.clone())
        }
    }
}

struct ScriptedCollective {
    outcome: CollectiveOutcome,
}

struct TransactionLinkBoundary;

#[derive(Default)]
struct RecordingDistributedRuntime {
    stops: Mutex<Vec<(uuid::Uuid, uuid::Uuid)>>,
}

impl DistributedRuntimeControl for RecordingDistributedRuntime {
    fn start(
        &self,
        _: &ClusterProposal,
        _: uuid::Uuid,
        _: uuid::Uuid,
        _: &DistributedExecutionSpec,
    ) -> Result<(), CoordinationError> {
        Ok(())
    }

    fn healthy(
        &self,
        _: &ClusterProposal,
        _: uuid::Uuid,
        _: uuid::Uuid,
    ) -> Result<bool, CoordinationError> {
        Ok(true)
    }

    fn stop(&self, cluster_id: uuid::Uuid, launch_id: uuid::Uuid) -> Result<(), CoordinationError> {
        self.stops.lock().push((cluster_id, launch_id));
        Ok(())
    }
}

impl ClusterLinkControl for TransactionLinkBoundary {
    fn apply(
        &self,
        _: &ClusterProposal,
        _: uuid::Uuid,
        _: ClusterLinkPhase,
    ) -> Result<(), CoordinationError> {
        Err(CoordinationError::Link("not exercised".into()))
    }

    fn prove(
        &self,
        _: &ClusterProposal,
        _: uuid::Uuid,
    ) -> Result<ClusterLinkProof, CoordinationError> {
        Err(CoordinationError::Link("not exercised".into()))
    }
}

impl CollectiveTesting for ScriptedCollective {
    fn run(&self) -> Result<CollectiveOutcome, ClusterError> {
        Ok(self.outcome)
    }
}

fn facts_for(node_ids: &[String], authority: &str, runtime: &str) -> Vec<cluster::MemberFacts> {
    node_ids
        .iter()
        .enumerate()
        .map(|(index, id)| cluster::MemberFacts {
            node_id: id.clone(),
            name: format!("Spark {}", char::from(b'A' + index as u8)),
            authority_fingerprint: authority.to_owned(),
            runtime_version: runtime.to_owned(),
            engine_image: "vllm:0.11".into(),
        })
        .collect()
}

fn healthy_report() -> LinkReport {
    LinkReport {
        interface: "cx5-0".into(),
        link_up: true,
        mtu: 9000,
        bandwidth_gbitps_ok: true,
    }
}

fn test_state(
    role: &'static str,
    link_report: LinkReport,
    collective: CollectiveOutcome,
) -> (
    AppState,
    TestClient,
    Arc<Mutex<Connection>>,
    tempfile::TempDir,
) {
    test_state_with_backends(
        role,
        Arc::new(ScriptedLink {
            report: link_report,
            fail: false,
        }),
        Arc::new(ScriptedCollective {
            outcome: collective,
        }),
        true,
    )
}

/// Inject cluster boundaries explicitly; tests may opt into a hypothetical coordinator that production never selects.
fn test_state_with_backends(
    role: &'static str,
    link: Arc<dyn LinkProbing>,
    collective: Arc<dyn CollectiveTesting>,
    coordinator_for_testing: bool,
) -> (
    AppState,
    TestClient,
    Arc<Mutex<Connection>>,
    tempfile::TempDir,
) {
    let dir = tempfile::tempdir().unwrap();
    let mut identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("coordinator")
        .unwrap();
    identity.public.node_id = SIGNING_NODE_ID;
    let conn = migrated_db();
    let client = TestClient {
        key: random_signing_key(),
        presence_key: random_signing_key(),
        device_id: uuid::Uuid::new_v4(),
        role,
    };
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
        &conn,
        &client.device_id,
        "test client",
        "macos",
        &spki,
        &sha256_hex(&spki),
        client.role,
        Some((&presence_spki, &presence_fingerprint)),
    )
    .unwrap();

    let database = Arc::new(Mutex::new(conn));
    let clock = Arc::new(ManualUtcClock::new(time::OffsetDateTime::now_utc()));
    let node_id = identity.node_id().to_string();
    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".to_owned(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "coordinator".to_owned(),
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
    let service = cluster::ClusterService::new(
        database.clone(),
        state.events.clone(),
        node_id,
        link,
        collective,
    );
    let service = if coordinator_for_testing {
        service.with_coordinator_for_testing()
    } else {
        service
    };
    let service = Arc::new(service);
    let state = state.with_cluster(service);
    (state, client, database, dir)
}

fn create_body(node_ids: &[String]) -> Value {
    json!({
        "name": "Studio pair",
        "member_node_ids": node_ids,
    })
}

fn record_peer_facts(database: &Arc<Mutex<Connection>>, facts: &[cluster::MemberFacts]) {
    let conn = database.lock();
    for fact in facts {
        cluster::record_peer_facts(
            &conn,
            &cluster::PeerFacts {
                node_id: fact.node_id.clone(),
                name: fact.name.clone(),
                authority_fingerprint: fact.authority_fingerprint.clone(),
                runtime_version: fact.runtime_version.clone(),
                engine_image: fact.engine_image.clone(),
            },
            "mutual_tls_test_fixture",
        )
        .unwrap();
    }
}

fn record_reciprocal_fabric_proof(
    database: &Arc<Mutex<Connection>>,
    left: &str,
    left_port: &str,
    right: &str,
    right_port: &str,
) {
    let conn = database.lock();
    for (observer, observer_port, peer, peer_port) in [
        (left, left_port, right, right_port),
        (right, right_port, left, left_port),
    ] {
        cluster::record_fabric_peer_proof(
            &conn,
            &cluster::FabricPeerProof {
                observer_node_id: observer.into(),
                observer_port_id: observer_port.into(),
                peer_node_id: peer.into(),
                peer_port_id: Some(peer_port.into()),
                verified_at: "2026-08-31T00:00:00Z".into(),
                expires_at: "2099-01-01T00:00:00Z".into(),
                source: cluster::FabricProofSource::MutualTlsChallenge,
            },
        )
        .unwrap();
    }
}

fn wait_for_operation(database: &Arc<Mutex<Connection>>, operation_id: &str) -> String {
    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(20));
        let state_row: Option<String> = {
            let conn = database.lock();
            conn.query_row(
                "SELECT state FROM operations WHERE id = ?1",
                [operation_id],
                |row| row.get(0),
            )
            .ok()
        };
        if let Some(state_row) = state_row
            && state_row != "running"
            && state_row != "requested"
        {
            return state_row;
        }
    }
    "timeout".into()
}

include!("cluster_flow/scenarios/unclustered_node_reports_standalone.rs");

include!(
    "cluster_flow/scenarios/external_import_preview_is_authenticated_read_only_and_supports_four_members.rs"
);

include!(
    "cluster_flow/scenarios/external_import_preview_refuses_non_owner_without_revealing_evidence.rs"
);

struct FixedFabricStatus {
    status: FabricStatus,
}

#[async_trait::async_trait]
impl FabricStatusProvider for FixedFabricStatus {
    async fn observe(&self, _observed_at: &str) -> FabricStatus {
        self.status.clone()
    }
}

include!(
    "cluster_flow/scenarios/fabric_endpoint_binds_only_reciprocal_authenticated_peer_evidence.rs"
);

include!("cluster_flow/scenarios/create_requires_owner_and_two_members.rs");

include!("cluster_flow/scenarios/create_requires_presence_but_exact_replay_does_not.rs");

include!("cluster_flow/scenarios/validate_requires_presence_but_exact_replay_does_not.rs");

include!("cluster_flow/scenarios/create_fails_closed_when_a_member_has_no_trusted_peer_record.rs");

include!("cluster_flow/scenarios/create_then_validate_walks_to_ready.rs");

include!("cluster_flow/scenarios/link_failure_fails_validation_and_collective_skip_degrades.rs");

include!("cluster_flow/scenarios/distributed_launch_plan_is_recipe_controlled.rs");

include!("cluster_flow/scenarios/compatibility_checks_reject_mixed_fleets.rs");

include!("cluster_flow/scenarios/create_is_refused_when_no_cluster_link_backend_is_installed.rs");

include!(
    "cluster_flow/scenarios/legacy_create_route_cannot_bypass_the_two_sided_transaction_backend.rs"
);

include!(
    "cluster_flow/scenarios/unqualified_distributed_launch_route_refuses_before_any_side_effect.rs"
);

include!(
    "cluster_flow/scenarios/an_existing_launch_can_be_listed_and_stopped_after_qualification_is_revoked.rs"
);

include!("cluster_flow/scenarios/create_is_refused_without_a_production_cluster_coordinator.rs");

include!("cluster_flow/scenarios/validate_is_refused_without_a_production_cluster_coordinator.rs");

include!("cluster_flow/scenarios/a_new_member_is_not_claimed_reachable_before_it_is_observed.rs");
