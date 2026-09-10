//! Schedule outbound macOS builds with signed recipes and verified worker evidence.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use parking_lot::Mutex;
use serde_json::{Value, json};
use spark_core::identity::NodeIdentity;
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

use crate::build_protocol::{
    BuildArtifactEvidence, BuildArtifactTicket, BuildClaim, BuildLease, BuildRecipePayload,
    BuildRequirements, BuildSourceTicket, MAX_ARTIFACT_BYTES, MAX_ARTIFACT_TOTAL_BYTES,
    MAX_ARTIFACTS, PROTOCOL_VERSION, SignedBuildRecipe, SignedBuildResult, safe_relative_path,
};
use crate::events::EventBus;
use crate::jobs::JobService;
use crate::project::{ProjectManager, ProjectView};
use crate::store;

pub const CLAIM_LEASE_SECONDS: i64 = 90;
pub const HEARTBEAT_SECONDS: u32 = 30;
pub const WORKER_LIVENESS_SECONDS: i64 = 90;
pub const SOURCE_LIMIT_BYTES: u64 = 2 * 1024 * 1024 * 1024;
pub const BUILD_ARTIFACT_STORAGE_LIMIT_BYTES: u64 = 512 * 1024 * 1024;

pub struct BuildService {
    pub projects: Arc<ProjectManager>,
    pub jobs: JobService,
    pub events: EventBus,
    identity: Arc<NodeIdentity>,
    work_dir: PathBuf,
    /// Serialize daemon claim transitions while SQLite predicates retain authority.
    claim_lock: Mutex<()>,
}

mod artifacts;
mod claims;
mod results;
mod submission;
mod validation;

use validation::{
    artifacts_match, constant_time_eq, parse_time, validate_requirements, validate_result_times,
    worker_matches,
};
pub use validation::{is_sha1_immutable, is_sha256};

impl BuildService {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        projects: Arc<ProjectManager>,
        jobs: JobService,
        events: EventBus,
        identity: Arc<NodeIdentity>,
        work_dir: PathBuf,
    ) -> Self {
        projects.set_build_work_dir(work_dir.clone());
        Self {
            projects,
            jobs,
            events,
            identity,
            work_dir,
            claim_lock: Mutex::new(()),
        }
    }

    pub fn register_worker(
        &self,
        name: &str,
        device_id: &Uuid,
        xcode_version: &str,
        platform_version: &str,
        capabilities: &Value,
        declared_worker_id: Option<Uuid>,
    ) -> Result<store::BuildWorkerRow, String> {
        let registered_at = self.jobs.now_rfc3339();
        let row = store::BuildWorkerRow {
            id: declared_worker_id.unwrap_or_else(Uuid::new_v4),
            display_name: name.to_owned(),
            device_id: *device_id,
            platform_version: platform_version.to_owned(),
            xcode_version: xcode_version.to_owned(),
            capabilities_json: capabilities.to_string(),
            state: "online".into(),
            registered_at: registered_at.clone(),
            last_seen_at: Some(registered_at.clone()),
            heartbeat_expires_at: Some(self.claims().deadline(WORKER_LIVENESS_SECONDS)?),
        };
        let conn = self.projects.db.lock();
        if let Some(existing) =
            store::build_worker_row(&conn, &row.id).map_err(|error| error.to_string())?
        {
            if existing.device_id != *device_id {
                return Err("BUILD_WORKER_ID_CONFLICT".into());
            }
            if existing.state == "revoked" {
                return Err("BUILD_WORKER_REVOKED".into());
            }
            store::refresh_build_worker_registration(&conn, &row, &registered_at)
                .map_err(|error| error.to_string())?;
        } else {
            store::insert_build_worker_at(&conn, &row, &registered_at)
                .map_err(|error| error.to_string())?;
        }
        self.events.emit_scoped(
            Some(&conn),
            &self.identity.node_id().to_string(),
            None,
            "build.worker.online",
            "info",
            json!({
                "worker_id": row.id,
                "display_name": row.display_name,
                "platform_version": row.platform_version,
                "xcode_version": row.xcode_version,
            }),
            crate::events::Visibility::min_role(crate::capability::Role::User),
        );
        Ok(row)
    }

    pub fn list_workers(&self) -> Result<Vec<store::BuildWorkerRow>, String> {
        let conn = self.projects.db.lock();
        let now = self.jobs.now();
        let mut workers = store::build_worker_rows(&conn).map_err(|e| e.to_string())?;
        for worker in &mut workers {
            if worker.state != "revoked"
                && worker
                    .heartbeat_expires_at
                    .as_deref()
                    .and_then(parse_time)
                    .is_none_or(|deadline| now >= deadline)
            {
                worker.state = "offline".into();
            }
        }
        Ok(workers)
    }

    /// The device a worker registration belongs to, if the worker exists.
    pub fn worker_owner(&self, worker_id: &Uuid) -> Result<Option<Uuid>, String> {
        let conn = self.projects.db.lock();
        Ok(store::build_worker_row(&conn, worker_id)
            .map_err(|e| e.to_string())?
            .map(|row| row.device_id))
    }

    pub fn workers_for_device(
        &self,
        device_id: &Uuid,
    ) -> Result<Vec<store::BuildWorkerRow>, String> {
        Ok(self
            .list_workers()?
            .into_iter()
            .filter(|w| w.device_id == *device_id)
            .collect())
    }

    /// Validate + queue a build job against an immutable commit.
    #[allow(clippy::too_many_arguments)]
    pub fn submit_build(
        &self,
        operation_id: Uuid,
        project: &ProjectView,
        commit: &str,
        source_sha256: &str,
        scheme: &str,
        configuration: &str,
        destination: &str,
        actions: Vec<String>,
        timeout_seconds: i64,
        requirements: &BuildRequirements,
        requested_by: &Uuid,
    ) -> Result<Uuid, String> {
        self.submission().submit_build(
            operation_id,
            project,
            commit,
            source_sha256,
            scheme,
            configuration,
            destination,
            actions,
            timeout_seconds,
            requirements,
            requested_by,
        )
    }

    /// Commit the replay record, operation and build input atomically in the caller transaction.
    #[allow(clippy::too_many_arguments)]
    pub fn submit_build_in(
        &self,
        conn: &rusqlite::Connection,
        operation_id: Uuid,
        project: &ProjectView,
        commit: &str,
        source_sha256: &str,
        scheme: &str,
        configuration: &str,
        destination: &str,
        actions: Vec<String>,
        timeout_seconds: i64,
        requirements: &BuildRequirements,
        requested_by: &Uuid,
    ) -> Result<Uuid, String> {
        self.submission().submit_build_in(
            conn,
            operation_id,
            project,
            commit,
            source_sha256,
            scheme,
            configuration,
            destination,
            actions,
            timeout_seconds,
            requirements,
            requested_by,
        )
    }

    pub fn get_build(&self, id: &Uuid) -> Result<store::BuildRow, String> {
        let conn = self.projects.db.lock();
        store::build_row(&conn, id)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "BUILD_NOT_FOUND".into())
    }

    pub fn heartbeat(&self, worker_id: &Uuid, device_id: &Uuid) -> Result<usize, String> {
        self.claims().heartbeat(worker_id, device_id)
    }

    /// Claim the oldest compatible job within the worker project ACL and advertised concurrency.
    pub fn claim_next(
        &self,
        worker_id: &Uuid,
        device_id: &Uuid,
        request_id: &Uuid,
    ) -> Result<Option<BuildClaim>, String> {
        self.claims().claim_next(worker_id, device_id, request_id)
    }

    /// Verify an unexpired build claim by constant-time comparison of its token digest.
    pub fn verify_claim(
        &self,
        build_id: &Uuid,
        worker_id: &Uuid,
        presented: &str,
    ) -> Result<store::BuildRow, &'static str> {
        self.claims().verify_claim(build_id, worker_id, presented)
    }

    pub fn renew_claim(
        &self,
        build_id: &Uuid,
        worker_id: &Uuid,
        claim_token: &str,
    ) -> Result<(String, bool), &'static str> {
        self.claims().renew_claim(build_id, worker_id, claim_token)
    }

    pub fn store_artifact(
        &self,
        build_id: &Uuid,
        worker_id: &Uuid,
        claim_token: &str,
        artifact_token: &str,
        evidence: &BuildArtifactEvidence,
        bytes: &[u8],
    ) -> Result<(), &'static str> {
        self.artifacts().store_artifact(
            build_id,
            worker_id,
            claim_token,
            artifact_token,
            evidence,
            bytes,
        )
    }

    pub fn record_result(
        &self,
        build_id: &Uuid,
        worker_id: &Uuid,
        claim_token: &str,
        device_public_key_spki: &[u8],
        result: &SignedBuildResult,
    ) -> Result<store::BuildRow, &'static str> {
        self.results().record_result(
            build_id,
            worker_id,
            claim_token,
            device_public_key_spki,
            result,
        )
    }

    pub fn read_artifact(
        &self,
        build_id: &Uuid,
        artifact_id: &Uuid,
    ) -> Result<(store::BuildArtifactRow, Vec<u8>), &'static str> {
        self.artifacts().read_artifact(build_id, artifact_id)
    }

    pub fn requeue_expired(&self) -> Result<usize, String> {
        self.claims().requeue_expired()
    }

    fn claims(&self) -> claims::Claims<'_> {
        claims::Claims {
            db: &self.projects.db,
            jobs: &self.jobs,
            identity: &self.identity,
            events: &self.events,
            work_dir: &self.work_dir,
            claim_lock: &self.claim_lock,
        }
    }

    fn submission(&self) -> submission::Submission<'_> {
        submission::Submission {
            db: &self.projects.db,
            jobs: &self.jobs,
        }
    }

    fn artifacts(&self) -> artifacts::Artifacts<'_> {
        artifacts::Artifacts {
            db: &self.projects.db,
            jobs: &self.jobs,
            work_dir: &self.work_dir,
            claims: self.claims(),
        }
    }

    fn results(&self) -> results::Results<'_> {
        results::Results {
            db: &self.projects.db,
            jobs: &self.jobs,
            identity: &self.identity,
            events: &self.events,
            work_dir: &self.work_dir,
            claims: self.claims(),
        }
    }
}
