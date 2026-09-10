//! Typed wire contracts and signing formats defined by `contracts/`.

pub mod generated;

/// Version tag used by the request-signing canonical payload (`SPARK2`).
pub const SIGNING_SCHEME: &str = "SPARK2";

/// Version tag for elevated-request proofs signed by the client presence-gated P-256 key.
pub const USER_PRESENCE_SIGNING_SCHEME: &str = "SPARK-PRESENCE2";
pub const USER_PRESENCE_PROOF_VERSION: u8 = 2;
pub const PAIRING_PRESENCE_SIGNING_SCHEME: &str = "SPARK-PAIRING-PRESENCE1";
pub const PRESENCE_ENROLLMENT_SIGNING_SCHEME: &str = "SPARK-PRESENCE-ENROLL2";

/// Decoded JSON carried as unpadded base64url in `X-Spark-User-Presence`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
pub struct UserPresenceHeader {
    pub version: u8,
    pub expires_at: String,
    pub signature: String,
}

/// Exact UTF-8 payload signed by the registered presence key.
#[allow(clippy::too_many_arguments)]
pub fn user_presence_canonical(
    method: &str,
    path_and_query: &str,
    timestamp: &str,
    nonce: &str,
    content_sha256: &str,
    device_id: &uuid::Uuid,
    expires_at: &str,
    node_id: &uuid::Uuid,
) -> String {
    format!(
        "{USER_PRESENCE_SIGNING_SCHEME}\n{}\n{path_and_query}\n{timestamp}\n{nonce}\n{content_sha256}\n{device_id}\n{expires_at}\n{node_id}",
        method.to_uppercase(),
    )
}

/// Pairing with a presence key binds both keys; legacy claims retain their challenge-signing bytes.
pub fn pairing_presence_canonical(
    challenge_base64url: &str,
    invitation_id: &uuid::Uuid,
    device_id: &uuid::Uuid,
    node_id: &uuid::Uuid,
    presence_key_fingerprint: &str,
) -> String {
    format!(
        "{PAIRING_PRESENCE_SIGNING_SCHEME}\n{challenge_base64url}\n{invitation_id}\n{device_id}\n{node_id}\n{presence_key_fingerprint}"
    )
}

/// Bind the actor, nonce and body digest in a separate proof to avoid a signature-inside-body hash cycle.
#[allow(clippy::too_many_arguments)]
pub fn presence_enrollment_canonical(
    method: &str,
    path_and_query: &str,
    timestamp: &str,
    nonce: &str,
    content_sha256: &str,
    device_id: &uuid::Uuid,
    presence_key_fingerprint: &str,
    node_id: &uuid::Uuid,
) -> String {
    format!(
        "{PRESENCE_ENROLLMENT_SIGNING_SCHEME}\n{}\n{path_and_query}\n{timestamp}\n{nonce}\n{content_sha256}\n{device_id}\n{presence_key_fingerprint}\n{node_id}",
        method.to_uppercase()
    )
}
