//! Cluster authorisation and the local half of the multi-member transaction.

use std::collections::{HashMap, HashSet};

use std::io::{Read, Write};

use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener, TcpStream};

use std::sync::Arc;

use std::thread;

use std::time::{Duration, Instant};

use ed25519_dalek::{Signature, Signer, Verifier, VerifyingKey};

use parking_lot::Mutex;

use rand::RngCore;

use rusqlite::{Connection, OptionalExtension};

use serde::{Deserialize, Serialize};

use serde_json::Value;

use sha2::{Digest, Sha256};

use spark_core::identity::NodeIdentity;

use spark_privd::protocol::{CLUSTER_FABRIC_CHALLENGE_PORT, ClusterLinkPhase, PrivilegedOperation};

use time::OffsetDateTime;

use uuid::Uuid;

use crate::cluster::{ClusterError, ClusterMemberRow, ClusterStatusRow, READY};

use crate::events::EventBus;

/// Remains false until the two-Spark qualification record is complete.
pub const CLUSTER_INFERENCE_QUALIFIED: bool = false;

/// §35.8: the only member count Spark Runtime will form or launch, until three-node hardware qualifies.
pub const MAXIMUM_SUPPORTED_MEMBERS: usize = 2;

/// Topology kinds this build can configure; a switched fabric needs its own hardware qualification.
pub const SUPPORTED_TOPOLOGIES: [&str; 1] = ["direct_qsfp"];

/// Member counts a physical qualification run has actually passed.
pub const VALIDATED_MEMBER_COUNTS: [usize; 1] = [MAXIMUM_SUPPORTED_MEMBERS];

#[derive(Debug, thiserror::Error)]
pub enum CoordinationError {
    #[error("invalid cluster proposal: {0}")]
    InvalidProposal(String),
    #[error("the owner device does not hold a live administrator grant on this Spark")]
    OwnerGrantMissing,
    #[error("a member grant is invalid: {0}")]
    InvalidGrant(String),
    #[error("cluster transaction conflict: {0}")]
    Conflict(String),
    #[error("cluster link phase failed: {0}")]
    Link(String),
    #[error("distributed runtime cleanup failed: {0}")]
    Runtime(String),
    #[error("storage error: {0}")]
    Storage(String),
}

impl From<rusqlite::Error> for CoordinationError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Storage(error.to_string())
    }
}

fn parse_uuid_column(value: String) -> rusqlite::Result<Uuid> {
    Uuid::parse_str(&value).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
    })
}

pub struct ClusterCoordinationService {
    database: Arc<Mutex<Connection>>,
    identity: Arc<NodeIdentity>,
    link: Arc<dyn ClusterLinkControl>,
    collective: Option<Arc<dyn ClusterCollectiveControl>>,
    peer_authenticator: Option<Arc<dyn ClusterPeerAuthenticator>>,
    runtime: Arc<dyn DistributedRuntimeControl>,
    runtime_version: Option<String>,
    engine_image: Option<String>,
    events: Option<EventBus>,
    monitor_failures: Mutex<HashMap<Uuid, u8>>,
    launch_failures: Mutex<HashMap<Uuid, tokio::sync::watch::Sender<Option<ClusterPeerLoss>>>>,
    transaction_admission: tokio::sync::Mutex<()>,
}

impl ClusterCoordinationService {
    pub fn new(
        database: Arc<Mutex<Connection>>,
        identity: Arc<NodeIdentity>,
        link: Arc<dyn ClusterLinkControl>,
        runtime: Arc<dyn DistributedRuntimeControl>,
    ) -> Self {
        Self {
            database,
            identity,
            link,
            collective: None,
            peer_authenticator: None,
            runtime,
            runtime_version: None,
            engine_image: None,
            events: None,
            monitor_failures: Mutex::new(HashMap::new()),
            launch_failures: Mutex::new(HashMap::new()),
            transaction_admission: tokio::sync::Mutex::new(()),
        }
    }

    pub fn with_engine_image(mut self, engine_image: Option<String>) -> Self {
        self.engine_image =
            engine_image.filter(|image| spark_privd::protocol::valid_pinned_image(image));
        self
    }

    pub fn with_runtime_version(mut self, runtime_version: impl Into<String>) -> Self {
        let runtime_version = runtime_version.into();
        self.runtime_version = (!runtime_version.is_empty()
            && runtime_version.len() <= 64
            && runtime_version == runtime_version.trim()
            && !runtime_version.chars().any(char::is_control))
        .then_some(runtime_version);
        self
    }

    pub fn with_collective(mut self, collective: Arc<dyn ClusterCollectiveControl>) -> Self {
        self.collective = Some(collective);
        self
    }

    pub fn with_peer_authenticator(
        mut self,
        peer_authenticator: Arc<dyn ClusterPeerAuthenticator>,
    ) -> Self {
        self.peer_authenticator = Some(peer_authenticator);
        self
    }

    pub fn with_events(mut self, events: EventBus) -> Self {
        self.events = Some(events);
        self
    }

    pub fn management_available(&self) -> bool {
        self.runtime_version.is_some()
            && self.engine_image.is_some()
            && self.collective.is_some()
            && self.peer_authenticator.is_some()
    }

    #[doc(hidden)]
    pub fn launch_failure_receiver(
        &self,
        launch_id: Uuid,
    ) -> tokio::sync::watch::Receiver<Option<ClusterPeerLoss>> {
        self.launch_failures
            .lock()
            .entry(launch_id)
            .or_insert_with(|| tokio::sync::watch::channel(None).0)
            .subscribe()
    }

    pub async fn transaction_guard(&self) -> tokio::sync::MutexGuard<'_, ()> {
        self.transaction_admission.lock().await
    }

    pub fn retained_grants(&self) -> Result<Vec<ClusterDeviceGrant>, CoordinationError> {
        self.transaction_repository().retained_grants()
    }

    pub fn local_descriptor(
        &self,
        runtime_version: &str,
    ) -> Result<ClusterMemberDescriptor, CoordinationError> {
        self.proof_validation().local_descriptor(runtime_version)
    }

    pub fn prepare(
        &self,
        proposal: &ClusterProposal,
        principal_device_id: Uuid,
        now: OffsetDateTime,
    ) -> Result<ClusterDeviceGrant, CoordinationError> {
        self.formation().prepare(proposal, principal_device_id, now)
    }

    pub fn activate(
        &self,
        proposal: &ClusterProposal,
        now: OffsetDateTime,
    ) -> Result<(), CoordinationError> {
        self.formation().activate(proposal, now)
    }

    pub fn prove(
        &self,
        proposal: &ClusterProposal,
        now: OffsetDateTime,
    ) -> Result<ClusterLinkProof, CoordinationError> {
        self.formation().prove(proposal, now)
    }

    pub fn run_collective(
        &self,
        proposal: &ClusterProposal,
        now: OffsetDateTime,
    ) -> Result<ClusterCollectiveProof, CoordinationError> {
        self.formation().run_collective(proposal, now)
    }

    pub fn commit(
        &self,
        proposal: &ClusterProposal,
        grants: &[ClusterDeviceGrant],
        proofs: &[ClusterLinkProof],
        collectives: &[ClusterCollectiveProof],
        now: OffsetDateTime,
    ) -> Result<ClusterCommitReceipt, CoordinationError> {
        self.commit_protocol()
            .commit(proposal, grants, proofs, collectives, now)
    }

    pub fn finalize(
        &self,
        proposal: &ClusterProposal,
        receipts: &[ClusterCommitReceipt],
        now: OffsetDateTime,
    ) -> Result<ClusterStatusRow, CoordinationError> {
        self.commit_protocol().finalize(proposal, receipts, now)
    }

    pub fn rollback(&self, proposal: &ClusterProposal) -> Result<(), CoordinationError> {
        self.recovery().rollback(proposal)
    }

    /// Gate advertised cluster inference on physical two-Spark qualification of the pinned image and topology.
    pub fn start_local_launch(
        &self,
        cluster_id: Uuid,
        launch_id: Uuid,
        execution: &DistributedExecutionSpec,
    ) -> Result<(), CoordinationError> {
        self.launch_control()
            .start_local_launch(cluster_id, launch_id, execution)
    }

    /// Retry idempotent launch steps until both exact Ray identities and the coordinator engine are verified.
    pub fn reconcile_preparing_launches_once(&self) -> Result<usize, CoordinationError> {
        self.launch_control().reconcile_preparing_launches_once()
    }

    pub fn launch_status(&self, launch_id: Uuid) -> Result<ClusterLaunchStatus, CoordinationError> {
        self.launch_control().launch_status(launch_id)
    }

    pub fn launches(&self) -> Result<Vec<ClusterLaunchStatus>, CoordinationError> {
        self.launch_control().launches()
    }

    pub fn stop_local_launch(
        &self,
        launch_id: Uuid,
    ) -> Result<ClusterLaunchStatus, CoordinationError> {
        self.launch_control().stop_local_launch(launch_id)
    }

    pub fn reconcile_stopping_launches_once(&self) -> Result<usize, CoordinationError> {
        self.launch_control().reconcile_stopping_launches_once()
    }

    /// Stop distributed work without erasing the signed membership record.
    pub fn handle_peer_loss(
        &self,
        cluster_id: Uuid,
        peer_node_id: Uuid,
    ) -> Result<ClusterPeerLoss, CoordinationError> {
        self.health_monitor()
            .handle_peer_loss(cluster_id, peer_node_id)
    }

    /// After three consecutive peer-path failures, stop distributed work before standalone recovery; report transient misses without teardown.
    pub fn monitor_committed_link_once(&self) -> Result<ClusterMonitorOutcome, CoordinationError> {
        self.health_monitor().monitor_committed_link_once()
    }

    pub fn reconcile_expired_transactions_once(
        &self,
        now: OffsetDateTime,
    ) -> Result<usize, CoordinationError> {
        self.recovery().reconcile_expired_transactions_once(now)
    }
}

impl From<ClusterError> for CoordinationError {
    fn from(error: ClusterError) -> Self {
        Self::Storage(error.to_string())
    }
}

#[cfg(test)]
#[path = "cluster_coordination/fabric_authentication_tests.rs"]
mod fabric_authentication_tests;

mod proposal;
use proposal::PROPOSAL_VERSION;
pub use proposal::{ClusterMemberDescriptor, ClusterProposal};

mod runtime_models;
use runtime_models::launch_status_from_row;
pub use runtime_models::{
    ClusterLaunchStatus, ClusterMonitorOutcome, ClusterPeerLoss, DistributedExecutionSpec,
};

mod grants;
pub use grants::{ClusterCommitReceipt, ClusterDeviceGrant};
use grants::{decode_verifying_key, verify_authority_signature};

mod link_proof;
use link_proof::LinkObservation;
pub use link_proof::{ClusterLinkControl, ClusterLinkProof};

mod fabric_proof;
pub use fabric_proof::ClusterFabricAuthenticationProof;
use fabric_proof::{
    FabricChallengeAcknowledgement, FabricChallengeCompletion, FabricChallengeHello,
    FabricChallengeResponse,
};

mod collective_proof;
pub use collective_proof::{
    ClusterCollectiveControl, ClusterCollectiveProof, ClusterPeerAuthenticator,
};

mod tcp_authentication;
pub use tcp_authentication::TcpClusterPeerAuthenticator;

mod privileged_adapters;
pub use privileged_adapters::{
    DistributedRuntimeControl, NoDistributedRuntime, PrivilegedClusterCollective,
    PrivilegedClusterLink, PrivilegedDistributedRuntime,
};

mod transaction_repository;

impl ClusterCoordinationService {
    fn transaction_repository(&self) -> transaction_repository::TransactionRepository<'_> {
        transaction_repository::TransactionRepository {
            database: self.database.as_ref(),
        }
    }
}

mod proof_validation;

impl ClusterCoordinationService {
    fn proof_validation(&self) -> proof_validation::ProposalValidation<'_> {
        proof_validation::ProposalValidation {
            identity: self.identity.as_ref(),
            runtime_version: &self.runtime_version,
            engine_image: &self.engine_image,
        }
    }
}

mod event_publisher;

impl ClusterCoordinationService {
    fn event_publisher(&self) -> event_publisher::CoordinationEvents<'_> {
        event_publisher::CoordinationEvents {
            database: self.database.as_ref(),
            identity: self.identity.as_ref(),
            events: &self.events,
        }
    }
}

mod failure_signal;

impl ClusterCoordinationService {
    fn failure_signal(&self) -> failure_signal::LaunchFailureSignal<'_> {
        failure_signal::LaunchFailureSignal {
            database: self.database.as_ref(),
            launch_failures: &self.launch_failures,
        }
    }
}

mod launch_control;

impl ClusterCoordinationService {
    fn launch_control(&self) -> launch_control::LaunchControl<'_> {
        launch_control::LaunchControl {
            database: self.database.as_ref(),
            identity: self.identity.as_ref(),
            runtime: self.runtime.as_ref(),
            validation: self.proof_validation(),
        }
    }
}

mod formation;

impl ClusterCoordinationService {
    fn formation(&self) -> formation::FormationControl<'_> {
        formation::FormationControl {
            database: self.database.as_ref(),
            identity: self.identity.as_ref(),
            link: self.link.as_ref(),
            validation: self.proof_validation(),
            repository: self.transaction_repository(),
            publisher: self.event_publisher(),
            collective: &self.collective,
            peer_authenticator: &self.peer_authenticator,
        }
    }
}

mod commit_protocol;

impl ClusterCoordinationService {
    fn commit_protocol(&self) -> commit_protocol::CommitProtocol<'_> {
        commit_protocol::CommitProtocol {
            database: self.database.as_ref(),
            identity: self.identity.as_ref(),
            link: self.link.as_ref(),
            validation: self.proof_validation(),
            repository: self.transaction_repository(),
            publisher: self.event_publisher(),
        }
    }
}

mod recovery;

impl ClusterCoordinationService {
    fn recovery(&self) -> recovery::TransactionRecovery<'_> {
        recovery::TransactionRecovery {
            database: self.database.as_ref(),
            identity: self.identity.as_ref(),
            link: self.link.as_ref(),
            launch_control: self.launch_control(),
        }
    }
}

mod health_monitor;

impl ClusterCoordinationService {
    fn health_monitor(&self) -> health_monitor::ClusterHealthMonitor<'_> {
        health_monitor::ClusterHealthMonitor {
            database: self.database.as_ref(),
            identity: self.identity.as_ref(),
            link: self.link.as_ref(),
            runtime: self.runtime.as_ref(),
            publisher: self.event_publisher(),
            launch_control: self.launch_control(),
            failure_signal: self.failure_signal(),
            monitor_failures: &self.monitor_failures,
        }
    }
}
