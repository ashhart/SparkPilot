//! Persist pairing, authorization and runtime records through transactional SQLite operations.

use rusqlite::{Connection, OptionalExtension, params};

use uuid::Uuid;

use crate::clock::{SystemUtcClock, UtcClock};

pub use spark_core::identity::PublicIdentity;

/// Error kind for store operations.
#[derive(Debug, thiserror::Error, Clone, PartialEq, Eq)]
pub enum StoreError {
    #[error("SQLite error: {0}")]
    Sqlite(String),
    #[error("the requested {0} was not found")]
    NotFound(&'static str),
    #[error("an owner already exists on this node")]
    OwnerAlreadyExists,
    #[error("invitation consumed or revoked")]
    InvitationUnavailable,
    #[error("invitation expired")]
    InvitationExpired,
    #[error("audit error: {0}")]
    Audit(String),
}

impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        StoreError::Sqlite(error.to_string())
    }
}

fn now() -> String {
    now_iso8601()
}

/// Display name of the temporary install-time administrator grant.
pub const INSTALLER_DEVICE_NAME: &str = "Spark Installer";

/// Use RFC3339 UTC for store helpers without a clock; stateful services should inject UtcClock.
pub fn now_iso8601() -> String {
    now_iso8601_with(&SystemUtcClock)
}

pub fn now_iso8601_with(clock: &dyn UtcClock) -> String {
    clock.now_rfc3339()
}

/// An RFC 3339 UTC timestamp `minutes` in the past, for windowed counting.
pub fn now_iso8601_minus_minutes(minutes: i64) -> String {
    let at = SystemUtcClock.now() - time::Duration::minutes(minutes);
    at.format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| now_iso8601())
}

fn parse_uuid(text: &str, index: usize) -> rusqlite::Result<uuid::Uuid> {
    uuid::Uuid::parse_str(text).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(index, rusqlite::types::Type::Text, Box::new(e))
    })
}

#[cfg(test)]
#[path = "store/pagination_tests.rs"]
mod pagination_tests;

#[cfg(test)]
#[path = "store/glm_retention.rs"]
mod glm_retention;

mod pairing;
pub use pairing::{
    ChallengeRow, ConsumedInvitationGrant, InvitationDraft, InvitationRow, active_join_code_exists,
    consume_challenge, consume_invitation, consumed_invitation_grant, has_owner, insert_challenge,
    insert_installer_device, insert_invitation, load_challenge, load_invitation,
    load_pending_invitation, load_pending_invitation_by_join_code, revoke_installer_grant_for,
};

mod devices;
pub use devices::{
    DeviceListRow, DeviceRow, NonceAdmission, PresenceKeyEnrollment, active_owner_count,
    admit_request_nonce, device_role, device_row, enroll_presence_key, insert_device,
    insert_device_with_presence_key, list_devices, load_active_device_role,
    load_device_by_fingerprint, load_device_by_id, load_presence_key_by_device_id,
    project_ids_for_device, revoke_device, update_device,
};

mod models;
pub use models::{
    ModelInventoryRow, list_model_rows, mark_model_available, mark_model_download_progress,
    mark_model_downloading, mark_model_installed, mark_model_unverified, model_row,
    remove_model_row, upsert_catalogue_model, upsert_model_file,
};

mod operations;
pub use operations::{
    OperationRow, live_operation_of_kind, operation_row, operation_rows, operation_rows_page,
    prune_events, prune_expired_records, prune_usage_daily,
};

mod terminals;
pub use terminals::{
    close_orphaned_terminals, close_terminal, has_non_terminal_operation, insert_terminal,
    terminal_row,
};

mod projects;
pub use projects::{
    ProjectRow, insert_project, insert_project_member, project_permission, project_row,
    project_rows, remove_project_row, update_project_state,
};

mod worktrees;
pub use worktrees::{WorktreeRow, insert_worktree, update_worktree_state, worktree_row};

mod changes;
pub use changes::{
    ChangeRow, agent_calls, change_row, change_rows, insert_agent_call, insert_change,
    set_change_approved, set_change_branch, set_change_merged, set_change_review_evidence,
    update_change_status, update_change_summaries,
};

mod approvals;
pub use approvals::{
    ApprovalRow, approval_for_resource, approval_row, decide_approval, insert_approval,
    insert_approval_with_evidence, update_approval_evidence,
};

mod workers;
pub use workers::{
    BuildWorkerRow, active_build_count_for_worker, build_worker_row, build_worker_rows,
    heartbeat_build_worker, insert_build_worker, insert_build_worker_at,
    refresh_build_worker_registration, update_build_worker_state, update_build_worker_state_at,
};

mod builds;
pub use builds::{
    BuildRow, build_claim_for_request, build_row, build_rows, insert_build, insert_build_at,
    update_build_result, update_build_result_at, update_build_status, update_build_status_at,
    update_build_worker, update_build_worker_at,
};

mod build_claims;
pub use build_claims::{
    cancel_expired_build, claim_build, clear_build_claim, expired_build_claims, finish_build_claim,
    renew_build_claim, requeue_expired_build, set_build_claim,
};

mod artifacts;
pub use artifacts::{
    BuildArtifactRow, build_artifact, build_artifact_usage, build_artifacts,
    delete_build_artifacts, insert_build_artifact,
};
