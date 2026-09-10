//! Expose cluster observation and durable management with owner or administrator authorization.

use axum::extract::{Extension, Path, State};

use axum::http::{HeaderMap, StatusCode};

use axum::response::Json;

use rusqlite::OptionalExtension;

use serde_json::{Value, json};

use sha2::{Digest, Sha256};

use crate::auth::{AuthenticatedRequest, Principal};

use crate::idempotency::{IdempotencyRequest, StoredResponse, json_response};

use crate::state::AppState;

const CLUSTER_RESOURCE: &str = "cluster";

const CREATE_ROUTE: &str = "/api/v1/cluster/create";

const VALIDATE_ROUTE: &str = "/api/v1/cluster/validate";

const PREPARE_TRANSACTION_ROUTE: &str = "/api/v1/cluster/transactions/prepare";

const ACTIVATE_TRANSACTION_ROUTE: &str = "/api/v1/cluster/transactions/activate";

const PROVE_TRANSACTION_ROUTE: &str = "/api/v1/cluster/transactions/prove";

const COLLECTIVE_TRANSACTION_ROUTE: &str = "/api/v1/cluster/transactions/collective";

const COMMIT_TRANSACTION_ROUTE: &str = "/api/v1/cluster/transactions/commit";

const FINALIZE_TRANSACTION_ROUTE: &str = "/api/v1/cluster/transactions/finalize";

const ROLLBACK_TRANSACTION_ROUTE: &str = "/api/v1/cluster/transactions/rollback";

const START_LAUNCH_ROUTE: &str = "/api/v1/cluster/launches";

const STOP_LAUNCH_ROUTE: &str = "/api/v1/cluster/launches/{launch_id}/stop";

fn internal_envelope(detail: &str) -> (StatusCode, Json<Value>) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({
            "error": { "code": "INTERNAL", "message": detail, "request_id": crate::route::current_request_id() }
        })),
    )
}

fn cluster_envelope(code: &str, message: &str, status: StatusCode) -> (StatusCode, Json<Value>) {
    (
        status,
        Json(json!({
            "error": { "code": code, "message": message, "request_id": crate::route::current_request_id() }
        })),
    )
}

fn presence_key(
    state: &AppState,
    principal: &Principal,
) -> Result<Option<Vec<u8>>, (StatusCode, Json<Value>)> {
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("no database"))?;
    let connection = database.lock();
    crate::store::load_presence_key_by_device_id(&connection, &principal.device_id)
        .map_err(|error| internal_envelope(&error.to_string()))
}

/// Return current cluster state.
pub async fn get_cluster(
    State(state): State<AppState>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let Some(cluster) = &state.cluster else {
        return Err(internal_envelope("cluster service unavailable"));
    };
    let row = cluster
        .status()
        .map_err(|e| internal_envelope(&e.to_string()))?;
    Ok(Json(serde_json::to_value(row).unwrap()))
}

/// Report signed member facts for an Apple coordinator to assemble one proposal.
pub async fn get_cluster_descriptor(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<crate::cluster_coordination::ClusterMemberDescriptor>, (StatusCode, Json<Value>)> {
    if principal.role != "owner" {
        return Err(cluster_envelope(
            "ROLE_FORBIDDEN",
            "cluster descriptors are owner-only",
            StatusCode::FORBIDDEN,
        ));
    }
    let coordinator = state.cluster_coordination.as_ref().ok_or_else(|| {
        cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this runtime has no cluster transaction backend",
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    coordinator
        .local_descriptor(&state.config.runtime_version)
        .map(Json)
        .map_err(coordination_error)
}

pub async fn get_cluster_grants(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Vec<crate::cluster_coordination::ClusterDeviceGrant>>, (StatusCode, Json<Value>)> {
    if principal.role != "owner" {
        return Err(cluster_envelope(
            "ROLE_FORBIDDEN",
            "cluster grants are owner-only",
            StatusCode::FORBIDDEN,
        ));
    }
    let coordinator = state.cluster_coordination.as_ref().ok_or_else(|| {
        cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this runtime has no cluster transaction backend",
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    coordinator
        .retained_grants()
        .map(Json)
        .map_err(coordination_error)
}

/// Report fabric observations with peer identities derived only from current reciprocal challenge records.
pub async fn get_fabric(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, crate::capability::Capability::NodeRead)
        .resource("fabric")
        .check()?;
    let observed_at = state.clock.now_rfc3339();
    let mut status = state.fabric_status.observe(&observed_at).await;
    status.observed_at.clone_from(&observed_at);
    if let Some(database) = &state.database {
        let links = crate::cluster::authenticated_fabric_links_for_node(
            &database.lock(),
            &state.identity.node_id().to_string(),
            &observed_at,
        )
        .map_err(|error| internal_envelope(&error.to_string()))?;
        crate::fabric::bind_authenticated_peers(
            &mut status,
            &state.identity.node_id().to_string(),
            &links,
        );
    }
    Ok(Json(serde_json::to_value(status).unwrap()))
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExternalClusterImportPreviewBody {
    pub name: String,
    pub member_node_ids: Vec<String>,
}

fn import_preview_error(error: crate::cluster::ClusterError) -> (StatusCode, Json<Value>) {
    use crate::cluster::ClusterError;
    match error {
        ClusterError::AlreadyClustered => cluster_envelope(
            "ALREADY_CLUSTERED",
            "this Spark already has a signed cluster identity",
            StatusCode::CONFLICT,
        ),
        ClusterError::MembershipTooSmall => cluster_envelope(
            "MEMBERSHIP_TOO_SMALL",
            "an external cluster candidate requires at least two members",
            StatusCode::UNPROCESSABLE_ENTITY,
        ),
        ClusterError::MembershipTooLarge => cluster_envelope(
            "MEMBERSHIP_TOO_LARGE",
            "a read-only external cluster candidate supports at most 64 members",
            StatusCode::UNPROCESSABLE_ENTITY,
        ),
        ClusterError::DuplicateMember => cluster_envelope(
            "MEMBERSHIP_DUPLICATE",
            "external cluster members must be distinct",
            StatusCode::UNPROCESSABLE_ENTITY,
        ),
        ClusterError::InvalidName | ClusterError::InvalidFabricProof(_) => cluster_envelope(
            "IMPORT_CANDIDATE_INVALID",
            "the external cluster candidate is invalid",
            StatusCode::UNPROCESSABLE_ENTITY,
        ),
        other => internal_envelope(&other.to_string()),
    }
}

/// Preview external-cluster import as an owner-only read without operations, presence consumption or membership registration.
pub async fn preview_external_cluster_import(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    _idempotency: IdempotencyRequest,
    axum::Json(body): axum::Json<ExternalClusterImportPreviewBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    if principal.role != "owner" {
        return Err(cluster_envelope(
            "ROLE_FORBIDDEN",
            "external cluster import preview is owner-only",
            StatusCode::FORBIDDEN,
        ));
    }
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("no database"))?;
    let preview = crate::cluster::preview_external_import(
        &database.lock(),
        &body.name,
        &body.member_node_ids,
        &state.clock.now_rfc3339(),
    )
    .map_err(import_preview_error)?;
    Ok(Json(serde_json::to_value(preview).unwrap()))
}

mod cluster_setup;
pub use cluster_setup::{CreateClusterBody, create_cluster, validate_cluster};

mod launches;
pub use launches::{
    StartClusterLaunchBody, get_cluster_launch, get_cluster_launches, start_cluster_launch,
    stop_cluster_launch,
};

mod transactions;
pub use transactions::{
    CommitClusterTransactionBody, FinalizeClusterTransactionBody, RollbackClusterTransactionBody,
    activate_cluster_transaction, commit_cluster_transaction, finalize_cluster_transaction,
    prepare_cluster_transaction, prove_cluster_transaction, rollback_cluster_transaction,
    run_cluster_collective,
};

mod transaction_admission;
use transaction_admission::{
    append_transaction_acceptance, coordination_error, lookup_transaction_replay,
    require_cluster_owner_presence, store_transaction_response,
};
