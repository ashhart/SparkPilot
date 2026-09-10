//! Define stateless text-chat placement with deployment digests distinct from friendly aliases and cluster ids.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_POOLS: usize = 16;
pub const MAX_GRANTS: usize = 128;
pub const MAX_RESERVATIONS: usize = 8192;
pub const MAX_LEASE_SECONDS: u64 = 30;
pub const MAX_GRANT_SECONDS: i64 = 86_400;
pub const NEW_REQUEST_WINDOW_MILLISECONDS: i64 = 120_000;
pub const REQUEST_FUTURE_SKEW_MILLISECONDS: i64 = 5_000;
pub const RESERVATION_RECEIPT_SECONDS: i64 = 600;
pub const MAX_REQUEST_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct InferencePoolPolicy {
    pub pool_id: Uuid,
    pub display_name: String,
    pub revision: u64,
    pub node_ids: Vec<Uuid>,
    pub caller_device_ids: Vec<Uuid>,
    pub deployment_ids: Vec<String>,
    pub router_device_ids: Vec<Uuid>,
    pub local_only: bool,
    pub paused: bool,
    pub max_concurrent_requests: u32,
    pub max_concurrent_per_caller: u32,
    pub max_queued_per_caller: u32,
    pub max_queued_requests: u32,
    pub max_buffered_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PoolPolicyPreviewRequest {
    pub expected_revision: u64,
    pub policy: InferencePoolPolicy,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PoolPolicyPreview {
    pub preview_id: Uuid,
    pub expected_revision: u64,
    pub expires_at: i64,
    pub policy: InferencePoolPolicy,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApplyPoolPolicyRequest {
    pub preview_id: Uuid,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RouterAction {
    Reserve,
    Execute,
    Status,
    Cancel,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateRouterGrantRequest {
    pub pool_id: Uuid,
    pub policy_revision: u64,
    pub router_device_id: Uuid,
    pub caller_device_id: Uuid,
    pub deployment_ids: Vec<String>,
    pub actions: Vec<RouterAction>,
    pub expires_in_seconds: u32,
}

/// A receipt for node-side authority; presenting its ID alone grants nothing.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RouterGrant {
    pub grant_id: Uuid,
    pub audience_node_id: Uuid,
    pub issued_by_device_id: Uuid,
    pub issued_at: i64,
    pub expires_at: i64,
    pub scope: CreateRouterGrantRequest,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeploymentIdentity {
    pub deployment_id: String,
    pub model_identity: String,
    pub model_id: String,
    pub source_repository: String,
    pub source_revision: String,
    pub recipe_sha256: String,
    pub profile_id: String,
    pub engine_image: String,
    pub runtime_version: String,
    pub generation: Uuid,
    pub context_length: u64,
    pub max_sequences: u32,
    pub capabilities: Vec<String>,
    pub qualification_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NodeCapabilitySnapshot {
    pub protocol_version: u32,
    pub node_id: Uuid,
    pub generation: Uuid,
    pub observed_at: i64,
    /// Receivers measure freshness using monotonic elapsed time after receipt.
    pub valid_for_milliseconds: u32,
    pub deployments: Vec<DeploymentIdentity>,
    pub active_reservations: u32,
    pub capacity_available: bool,
    pub exclusion_codes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReserveInferenceRequest {
    pub grant_id: Uuid,
    pub pool_id: Uuid,
    pub caller_device_id: Uuid,
    /// UUIDv7; new IDs are at most 120s old or 5s in the future.
    pub request_id: Uuid,
    pub attempt_id: Uuid,
    pub deployment_id: String,
    pub request_sha256: String,
    pub request_bytes: u32,
    pub policy_revision: u64,
    pub context_budget: u64,
    pub output_budget: u32,
    pub lease_seconds: u32,
    pub required_capabilities: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReservationState {
    Reserved,
    Accepted,
    CancelRequested,
    OutcomeUnknown,
    Succeeded,
    Failed,
    Cancelled,
    Expired,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AdmissionReservation {
    pub reservation_id: Uuid,
    pub node_id: Uuid,
    pub request_id: Uuid,
    pub attempt_id: Uuid,
    pub pool_id: Uuid,
    pub caller_device_id: Uuid,
    pub deployment_id: String,
    pub engine_instance_id: Uuid,
    pub capacity_released: bool,
    pub policy_revision: u64,
    pub context_budget: u64,
    pub output_budget: u32,
    pub state: ReservationState,
    pub expires_at: i64,
    pub reason: Option<String>,
}
