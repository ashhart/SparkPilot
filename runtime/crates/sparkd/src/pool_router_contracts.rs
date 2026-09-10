//! Owner-anchored service identity enrollment; independent of Apple devices.
use serde::{Deserialize, Serialize};
use uuid::Uuid;
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RouterIdentityDocument {
    pub protocol_version: u32,
    pub router_node_id: Uuid,
    pub principal_id: Uuid,
    pub key_generation: u64,
    pub request_public_key_spki: String,
    pub request_key_fingerprint: String,
    pub authority_public_key: String,
    pub authority_fingerprint: String,
    pub authority_signature: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PrepareRouterIdentityRequest {
    /// Absent prepares/reads the current key; present explicitly rotates this key.
    pub expected_key_fingerprint: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RouterPeerTrust {
    pub node_id: Uuid,
    pub authority_fingerprint: String,
    pub tls_certificate_sha256: String,
    /// Numeric, on-link local HTTPS endpoint; no hostname, query or credentials.
    pub endpoint: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RouterRecipientRetirement {
    NotRequested,
    Unconfirmed,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RouterPeerRecord {
    pub recipient: RouterPeerTrust,
    pub principal_id: Uuid,
    pub approved_at: i64,
    pub uses_current_key: bool,
    /// Local key replacement does not prove remote revocation; old records remain.
    pub recipient_retirement: RouterRecipientRetirement,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RouterPeerInventory {
    pub current_principal_id: Uuid,
    pub peers: Vec<RouterPeerRecord>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateRouterEnrollmentRequest {
    pub identity: RouterIdentityDocument,
    /// Independently read from the owner's already verified source connection.
    pub expected_router_node_id: Uuid,
    pub expected_router_authority_fingerprint: String,
    pub display_name: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RouterEnrollmentChallenge {
    pub challenge_id: Uuid,
    pub nonce: String,
    pub issued_at: i64,
    pub expires_at: i64,
    pub recipient_node_id: Uuid,
    pub recipient_authority_public_key: String,
    pub recipient_authority_fingerprint: String,
    pub recipient_tls_certificate_sha256: String,
    pub router_identity: RouterIdentityDocument,
    pub recipient_authority_signature: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProveRouterEnrollmentRequest {
    pub challenge: RouterEnrollmentChallenge,
    /// Independently read from the owner's already pinned destination connection.
    pub recipient: RouterPeerTrust,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RouterEnrollmentProof {
    pub challenge_id: Uuid,
    pub recipient_node_id: Uuid,
    pub principal_id: Uuid,
    pub challenge_sha256: String,
    pub possession_signature: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnrolledRouterPrincipal {
    pub principal_id: Uuid,
    pub kind: String,
    pub router_node_id: Uuid,
    pub request_key_fingerprint: String,
    pub recipient_node_id: Uuid,
    pub display_name: String,
    pub enrolled_at: i64,
    pub revoked: bool,
}
