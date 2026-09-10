//! Coordinate two-Spark membership and launches with one designated sequencer; this is not two-member consensus.

use std::collections::HashSet;

use std::sync::Arc;

use parking_lot::Mutex;

use rusqlite::{Connection, OptionalExtension};

use serde::Serialize;

use serde_json::{Value, json};

use crate::events::EventBus;

pub use crate::cluster_import::{
    AuthenticatedFabricLink, EXTERNALLY_CONFIGURED, ExternalClusterImportPreview,
    ExternalImportBlocker, ExternalImportMember, FabricPeerProof, FabricProofSource,
    authenticated_fabric_links_for_node, preview_external_import, record_fabric_peer_proof,
};

#[derive(Debug, thiserror::Error)]
pub enum ClusterError {
    #[error("a cluster already exists on this node")]
    AlreadyClustered,
    #[error("clusters require at least two members")]
    MembershipTooSmall,
    #[error("cluster members must be distinct")]
    DuplicateMember,
    #[error("the coordinator node must be included as a cluster member")]
    CoordinatorMissing,
    #[error("member authorities differ; clusters require one authority (§35.2)")]
    AuthorityMismatch,
    #[error("member runtime versions differ: {0}")]
    VersionMismatch(String),
    #[error("the QSFP link is not healthy: {0}")]
    LinkUnhealthy(String),
    #[error("the collective test failed: {0}")]
    CollectiveTestFailed(String),
    #[error("no cluster exists on this node")]
    NotClustered,
    #[error("member node {0} has no trusted peer record")]
    UnknownPeer(String),
    #[error("cluster names must contain between 1 and 120 characters")]
    InvalidName,
    #[error("read-only cluster imports support at most 64 members")]
    MembershipTooLarge,
    #[error("invalid fabric peer proof: {0}")]
    InvalidFabricProof(String),
    #[error("storage error: {0}")]
    Storage(String),
}

impl From<rusqlite::Error> for ClusterError {
    fn from(error: rusqlite::Error) -> Self {
        ClusterError::Storage(error.to_string())
    }
}

/// Cluster lifecycle states (contract `Cluster.state`).
pub const STANDALONE: &str = "standalone";

pub const FORMING: &str = "forming";

pub const VALIDATING: &str = "validating";

pub const READY: &str = "ready";

pub const DEGRADED: &str = "degraded";

pub const FAILED: &str = "failed";

/// The `Cluster` contract document.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ClusterStatusRow {
    pub id: Option<String>,
    pub name: Option<String>,
    pub state: String,
    pub members: Vec<ClusterMemberRow>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ClusterMemberRow {
    pub node_id: String,
    pub name: String,
    pub role: String,
    pub reachable: bool,
    pub qsfp_health: Option<String>,
}

pub struct ClusterService {
    database: Arc<Mutex<Connection>>,
    events: EventBus,
    node_id: String,
    link: Arc<dyn LinkProbing>,
    collective: Arc<dyn CollectiveTesting>,
    coordinator_available: bool,
}

impl ClusterService {
    pub fn new(
        database: Arc<Mutex<Connection>>,
        events: EventBus,
        node_id: String,
        link: Arc<dyn LinkProbing>,
        collective: Arc<dyn CollectiveTesting>,
    ) -> Self {
        Self {
            database,
            events,
            node_id,
            link,
            collective,
            coordinator_available: false,
        }
    }

    /// Enable hypothetical coordinator lifecycle tests without making incomplete production coordination available.
    #[doc(hidden)]
    pub fn with_coordinator_for_testing(mut self) -> Self {
        self.coordinator_available = true;
        self
    }

    /// Permit cluster mutation only when every member can be authenticated, prepared, committed and rolled back.
    pub fn management_available(&self) -> bool {
        self.coordinator_available && self.link.backend_installed()
    }

    /// Return standalone state with no members when this node is unclustered.
    pub fn status(&self) -> Result<ClusterStatusRow, ClusterError> {
        let conn = self.database.lock();
        let state: Option<(String, String, String)> = conn
            .query_row(
                "SELECT id, name, state FROM cluster_state WHERE singleton = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .map(Some)
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(other),
            })?;

        let Some((id, name, state)) = state else {
            return Ok(ClusterStatusRow {
                id: None,
                name: None,
                state: STANDALONE.into(),
                members: vec![],
            });
        };

        let mut stmt = conn.prepare(
            "SELECT node_id, name, role, reachable, qsfp_health
             FROM cluster_members WHERE cluster_id = ?1 ORDER BY role DESC, node_id",
        )?;
        let members = stmt
            .query_map([&id], |row| {
                Ok(ClusterMemberRow {
                    node_id: row.get(0)?,
                    name: row.get(1)?,
                    role: row.get(2)?,
                    reachable: row.get::<_, i64>(3)? == 1,
                    qsfp_health: row.get(4)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(ClusterStatusRow {
            id: Some(id),
            name: Some(name),
            state,
            members,
        })
    }

    /// Create a leader-owned cluster only when every member presents the same authority fingerprint.
    pub fn create(
        &self,
        name: &str,
        facts: &[MemberFacts],
    ) -> Result<ClusterStatusRow, ClusterError> {
        if facts.len() < 2 {
            return Err(ClusterError::MembershipTooSmall);
        }
        let unique_members = facts
            .iter()
            .map(|member| member.node_id.as_str())
            .collect::<HashSet<_>>();
        if unique_members.len() != facts.len() {
            return Err(ClusterError::DuplicateMember);
        }
        check_authority(facts)?;
        check_compatibility(facts)?;
        if !facts.iter().any(|member| member.node_id == self.node_id) {
            return Err(ClusterError::CoordinatorMissing);
        }
        {
            let mut conn = self.database.lock();
            let transaction = conn.transaction()?;
            let exists: i64 = transaction.query_row(
                "SELECT COUNT(*) FROM cluster_state WHERE singleton = 1",
                [],
                |row| row.get(0),
            )?;
            if exists > 0 {
                return Err(ClusterError::AlreadyClustered);
            }

            let cluster_id = uuid::Uuid::new_v4().to_string();
            let now = crate::store::now_iso8601();
            transaction.execute(
                "INSERT INTO cluster_state (singleton, id, name, state, created_at, updated_at)
                 VALUES (1, ?1, ?2, ?3, ?4, ?4)",
                rusqlite::params![cluster_id, name, VALIDATING, now],
            )?;
            for member in facts {
                let is_coordinator = member.node_id == self.node_id;
                let role = if is_coordinator { "leader" } else { "worker" };
                // Mark peers reachable only after observation, never merely because membership was created.
                let reachable = is_coordinator as i64;
                transaction.execute(
                    "INSERT INTO cluster_members
                        (cluster_id, node_id, name, role, authority_fingerprint,
                         reachable, runtime_version, last_seen_at, metadata_json)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, '{}')",
                    rusqlite::params![
                        cluster_id,
                        member.node_id,
                        member.name,
                        role,
                        member.authority_fingerprint,
                        reachable,
                        member.runtime_version,
                        now
                    ],
                )?;
            }
            transaction.commit()?;
        }
        self.emit(
            "cluster.node.joined",
            "notice",
            json!({ "members": facts.len() }),
        );
        self.status()
    }

    /// Validate link and collective operation before choosing ready, degraded or failed state.
    pub fn validate(&self) -> Result<ClusterStatusRow, ClusterError> {
        let current = self.status()?;
        if current.state == STANDALONE {
            return Err(ClusterError::NotClustered);
        }

        let report = match self.link.probe() {
            Ok(report) => report,
            Err(error) => {
                self.set_state(FAILED)?;
                self.emit(
                    "cluster.degraded",
                    "error",
                    json!({ "reason": "link_probe_failed", "detail": error.to_string() }),
                );
                return Err(error);
            }
        };
        if !report.link_up || !report.bandwidth_gbitps_ok {
            self.set_state(FAILED)?;
            self.emit(
                "cluster.link.changed",
                "error",
                json!({ "interface": report.interface, "link_up": report.link_up }),
            );
            return Err(ClusterError::LinkUnhealthy(report.interface));
        }
        self.emit(
            "cluster.validation.progress",
            "info",
            json!({ "stage": "link", "mtu": report.mtu }),
        );

        match self.collective.run()? {
            CollectiveOutcome::Passed => {
                self.set_state(READY)?;
                self.emit("cluster.ready", "notice", json!({}));
            }
            CollectiveOutcome::Skipped => {
                self.set_state(DEGRADED)?;
                self.emit(
                    "cluster.degraded",
                    "warning",
                    json!({ "reason": "collective_test_skipped" }),
                );
            }
            CollectiveOutcome::Failed => {
                self.set_state(FAILED)?;
                self.emit(
                    "cluster.degraded",
                    "error",
                    json!({ "reason": "collective_test_failed" }),
                );
                return Err(ClusterError::CollectiveTestFailed(
                    "collective test reported failure".into(),
                ));
            }
        }
        self.status()
    }

    /// Degrade the cluster visibly when worker health is lost.
    pub fn mark_member_reachable(
        &self,
        node_id: &str,
        reachable: bool,
    ) -> Result<(), ClusterError> {
        {
            let conn = self.database.lock();
            conn.execute(
                "UPDATE cluster_members SET reachable = ?1, last_seen_at = ?2
                 WHERE node_id = ?3",
                rusqlite::params![reachable as i64, crate::store::now_iso8601(), node_id],
            )?;
        }
        if !reachable {
            self.set_state(DEGRADED)?;
            self.emit(
                "cluster.node.left",
                "warning",
                json!({ "node_id": node_id, "reason": "unreachable" }),
            );
        }
        Ok(())
    }

    /// Dissolve: remove membership and state.
    pub fn dissolve(&self) -> Result<ClusterStatusRow, ClusterError> {
        {
            let conn = self.database.lock();
            conn.execute("DELETE FROM cluster_members", [])?;
            conn.execute("DELETE FROM cluster_state WHERE singleton = 1", [])?;
        }
        self.emit(
            "cluster.node.left",
            "notice",
            json!({ "reason": "dissolved" }),
        );
        self.status()
    }

    fn set_state(&self, state: &str) -> Result<(), ClusterError> {
        let conn = self.database.lock();
        conn.execute(
            "UPDATE cluster_state SET state = ?1, updated_at = ?2 WHERE singleton = 1",
            rusqlite::params![state, crate::store::now_iso8601()],
        )?;
        Ok(())
    }

    fn emit(&self, event_type: &str, severity: &str, payload: Value) {
        let conn = self.database.lock();
        self.events.emit(
            Some(&conn),
            &self.node_id,
            None,
            event_type,
            severity,
            payload,
        );
    }
}

mod peers;
pub use peers::{
    MemberFacts, PeerFacts, check_authority, check_compatibility, peer_facts, record_peer_facts,
    resolve_cluster_member_facts,
};

mod qualification;
pub use qualification::{
    CollectiveOutcome, CollectiveTesting, DistributedLaunchPlan, LinkProbing, LinkReport,
    NoCollectiveTest, NoLinkProbe,
};
