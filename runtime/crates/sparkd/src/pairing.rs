//! Sign invitations/challenges with node Ed25519 authority and verify device P-256 request and distinct presence keys.

use ed25519_dalek::{Signature, Signer, Verifier};

use p256::ecdsa::Signature as P256Signature;

use p256::ecdsa::VerifyingKey as P256Verify;

use p256::pkcs8::{DecodePublicKey, EncodePublicKey};

use rand::{Rng, RngCore};

use rusqlite::Connection;

use serde::{Deserialize, Serialize};

use time::OffsetDateTime;

use spark_core::identity::NodeIdentity;

use crate::crypto::{base64url_decode, base64url_encode, sha256_hex};

use crate::store;

use crate::store::StoreError;

pub const INVITATION_MIN_SECONDS: i64 = 60;

/// Cap invitation bearer lifetime at fifteen minutes regardless of configuration; default lifetime is five minutes (§15.3).
pub const INVITATION_MAX_SECONDS: i64 = 900;

/// Default invitation lifetime from protocol section 15.3.
pub const INVITATION_DEFAULT_SECONDS: i64 = 300;

pub const CHALLENGE_LIFETIME_SECONDS: i64 = 300;

pub const ROLES: &[&str] = &["owner", "administrator", "developer", "user", "observer"];

#[derive(Debug, thiserror::Error)]
pub enum PairingError {
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
    #[error("mercurial time format")]
    Time(#[from] time::error::Parse),
    #[error("invalid invitation: {0}")]
    InvalidInvitation(String),
    #[error("join code is invalid or expired")]
    InvalidJoinCode,
    #[error(
        "too many join codes have been tried on this Spark recently; retry after {retry_after_seconds}s"
    )]
    TooManyJoinCodeAttempts { retry_after_seconds: u64 },
    #[error("invitation {0} is not valid for this role")]
    RoleMismatch(&'static str),
    #[error("an owner already exists on this node")]
    OwnerAlreadyExists,
    #[error("challenge {0} is not valid for this pairing attempt")]
    ChallengeMismatch(String),
    #[error("device signature verification failed")]
    BadDeviceSignature,
    #[error("invalid device public key: {0}")]
    BadPublicKey(String),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
}

impl From<base64::DecodeError> for PairingError {
    fn from(error: base64::DecodeError) -> Self {
        PairingError::InvalidInvitation(format!("base64: {error}"))
    }
}

fn rfc3339(dt: OffsetDateTime) -> String {
    dt.format(&time::format_description::well_known::Rfc3339)
        .expect("RFC3339 formatting is infallible")
}

fn parse_rfc3339(text: &str) -> Result<OffsetDateTime, time::error::Parse> {
    OffsetDateTime::parse(text, &time::format_description::well_known::Rfc3339)
}

/// Compare public ASCII digests without exposing matching-prefix length through early return.
fn constant_time_equals(left: &str, right: &str) -> bool {
    let a = left.as_bytes();
    let b = right.as_bytes();
    if a.len() != b.len() {
        return false;
    }
    let mut difference = 0u8;
    for index in 0..a.len() {
        difference |= a[index] ^ b[index];
    }
    difference == 0
}

fn sha256_fingerprint_bytes(data: &[u8]) -> Vec<u8> {
    sha256_hex(data).into_bytes()
}

/// Request body for `POST /api/v1/pairing/challenge`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct ChallengeRequest {
    pub invitation_id: uuid::Uuid,
    pub device_public_key_spki: String, // base64 (contentEncoding: base64)
}

/// Response body for the challenge endpoint.
#[derive(Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct ChallengeResponse {
    pub challenge_id: uuid::Uuid,
    pub challenge: String, // base64url
    pub expires_at: String,
    pub authority_fingerprint: String,
    pub signature: String, // base64url Ed25519 by node authority
}

pub fn create_challenge(
    conn: &Connection,
    identity: &NodeIdentity,
    request: &ChallengeRequest,
) -> Result<ChallengeResponse, PairingError> {
    let device_fingerprint = canonical_p256_key(&request.device_public_key_spki)?.fingerprint;
    let invitation = match store::load_pending_invitation(conn, &request.invitation_id)? {
        Some(invitation) => invitation,
        None => match store::consumed_invitation_grant(conn, &request.invitation_id)? {
            // Allow fresh challenges for lost-response recovery only for the granted key; claim rechecks every binding inside its transaction.
            Some(grant) if grant.public_key_fingerprint == device_fingerprint => grant.invitation,
            Some(_) => return Err(StoreError::InvitationUnavailable.into()),
            None => {
                // Distinguish unknown invitations from revoked invitations or those consumed by another key.
                if store::load_invitation(conn, &request.invitation_id)?.is_some() {
                    return Err(StoreError::InvitationUnavailable.into());
                }
                return Err(StoreError::NotFound("invitation").into());
            }
        },
    };

    let signed: InvitationPayload = serde_json::from_str(&invitation.signed_payload_json)?;
    match (
        signed.recipient_device_id,
        signed.recipient_public_key_fingerprint.as_deref(),
    ) {
        (None, None) => {}
        (Some(_), Some(expected)) if expected == device_fingerprint => {}
        (Some(_), Some(_)) => {
            return Err(PairingError::ChallengeMismatch(
                "invitation is bound to a different device key".into(),
            ));
        }
        _ => {
            return Err(PairingError::InvalidInvitation(
                "recipient binding is incomplete".into(),
            ));
        }
    }

    // Check row structure here; claim enforces expiry against the wall clock.
    let _ = invitation.id;

    let mut challenge_bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut challenge_bytes);

    let challenge_id = uuid::Uuid::new_v4();
    let expires_at =
        OffsetDateTime::now_utc() + time::Duration::seconds(CHALLENGE_LIFETIME_SECONDS);

    store::insert_challenge(
        conn,
        &challenge_id,
        &request.invitation_id,
        &challenge_bytes,
        &device_fingerprint,
        &rfc3339(expires_at),
    )?;

    // Sign the challenge envelope for clients that already trust this node's authority fingerprint.
    let canonical = format!(
        "{}\n{}\n{}\n{}",
        challenge_id,
        base64url_encode(&challenge_bytes),
        rfc3339(expires_at),
        identity.fingerprint(),
    );
    let signature = identity.signing_key().sign(canonical.as_bytes());

    Ok(ChallengeResponse {
        challenge_id,
        challenge: base64url_encode(&challenge_bytes),
        expires_at: rfc3339(expires_at),
        authority_fingerprint: identity.fingerprint().to_owned(),
        signature: base64url_encode(&signature.to_bytes()),
    })
}

#[cfg(test)]
#[path = "pairing/join_code_attempt_tests.rs"]
mod join_code_attempt_tests;

mod public_keys;
pub(crate) use public_keys::{canonical_p256_key, canonical_p256_key_der};

mod invitations;
pub use invitations::{
    GUEST_INVITATION_MAX_SECONDS, GUEST_ROLE, INVITATION_VERSION_WITH_ROUTES, InvitationPayload,
    InvitationRoutes, IssuedInvitation, JOIN_CODE_FAILURE_WINDOW_MINUTES, MAX_FAILED_JOIN_CODES,
    SharedAccessSummary, issue_guest_invitation, issue_invitation, issue_invitation_for_recipient,
    join_code_failures_in_window, redeem_join_code,
};

mod claims;
pub(crate) use claims::claim_refusal_is_auditable;
pub use claims::{ClaimRequest, ClaimResponse, DeviceGrant, claim_invitation};
