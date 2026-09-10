//! Fresh, cryptographic user-presence proof for device revocation.

use axum::http::HeaderValue;
use p256::ecdsa::signature::Verifier as _;
use p256::pkcs8::DecodePublicKey as _;
use time::OffsetDateTime;

use crate::auth::AuthenticatedRequest;
use crate::crypto::base64url_decode;

pub const HEADER_USER_PRESENCE: &str = "x-spark-user-presence";
pub const HEADER_PRESENCE_KEY_PROOF: &str = "x-spark-presence-key-proof";
pub const PROOF_LIFETIME_SECONDS: i64 = 60;
const MAX_HEADER_BYTES: usize = 512;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PresenceError {
    Required,
    NotRegistered,
    Expired,
    Invalid,
}

impl PresenceError {
    pub fn code(self) -> &'static str {
        match self {
            Self::Required => "USER_PRESENCE_REQUIRED",
            Self::NotRegistered => "USER_PRESENCE_NOT_REGISTERED",
            Self::Expired => "USER_PRESENCE_EXPIRED",
            Self::Invalid => "USER_PRESENCE_INVALID",
        }
    }
}

pub fn verify(
    header: Option<&HeaderValue>,
    presence_public_key_spki: Option<&[u8]>,
    request: &AuthenticatedRequest,
    now: OffsetDateTime,
) -> Result<(), PresenceError> {
    let header = header.ok_or(PresenceError::Required)?;
    let header = header.to_str().map_err(|_| PresenceError::Invalid)?;
    if header.len() > MAX_HEADER_BYTES {
        return Err(PresenceError::Invalid);
    }
    let public_key = presence_public_key_spki.ok_or(PresenceError::NotRegistered)?;
    let decoded = base64url_decode(header).map_err(|_| PresenceError::Invalid)?;
    let proof: spark_contracts::UserPresenceHeader =
        serde_json::from_slice(&decoded).map_err(|_| PresenceError::Invalid)?;
    if proof.version != spark_contracts::USER_PRESENCE_PROOF_VERSION {
        return Err(PresenceError::Invalid);
    }

    let expires_at = OffsetDateTime::parse(
        &proof.expires_at,
        &time::format_description::well_known::Rfc3339,
    )
    .map_err(|_| PresenceError::Invalid)?;
    if expires_at <= now {
        return Err(PresenceError::Expired);
    }
    if (expires_at - now).whole_seconds() > PROOF_LIFETIME_SECONDS {
        return Err(PresenceError::Invalid);
    }
    let request_timestamp = OffsetDateTime::parse(
        &request.timestamp,
        &time::format_description::well_known::Rfc3339,
    )
    .map_err(|_| PresenceError::Invalid)?;
    let lifetime = (expires_at - request_timestamp).whole_seconds();
    if !(1..=PROOF_LIFETIME_SECONDS).contains(&lifetime) {
        return Err(PresenceError::Invalid);
    }

    let signature_bytes = base64url_decode(&proof.signature).map_err(|_| PresenceError::Invalid)?;
    let signature =
        p256::ecdsa::Signature::from_slice(&signature_bytes).map_err(|_| PresenceError::Invalid)?;
    let verifying_key = p256::ecdsa::VerifyingKey::from_public_key_der(public_key)
        .map_err(|_| PresenceError::NotRegistered)?;
    let canonical = spark_contracts::user_presence_canonical(
        &request.method,
        &request.path_and_query,
        &request.timestamp,
        &request.nonce,
        &request.content_sha256,
        &request.device_id,
        &proof.expires_at,
        &request.node_id,
    );
    verifying_key
        .verify(canonical.as_bytes(), &signature)
        .map_err(|_| PresenceError::Invalid)
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::ecdsa::signature::Signer as _;
    use p256::pkcs8::EncodePublicKey as _;
    use time::format_description::well_known::Rfc3339;

    fn signing_key() -> p256::ecdsa::SigningKey {
        p256::ecdsa::SigningKey::from_slice(&[7; 32]).unwrap()
    }

    fn request() -> AuthenticatedRequest {
        AuthenticatedRequest {
            node_id: uuid::Uuid::from_u128(2),
            method: "DELETE".into(),
            path_and_query: "/api/v1/devices/8c55ac55-38c1-43cf-b123-8e546f80a66e".into(),
            timestamp: "2026-08-28T14:20:30Z".into(),
            nonce: "A8r2KqYs-Vu4Z5cN".into(),
            content_sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                .into(),
            device_id: uuid::Uuid::parse_str("e3778301-3007-47f1-86cd-92dc0eaf4dc5").unwrap(),
        }
    }

    fn encoded_proof(
        key: &p256::ecdsa::SigningKey,
        request: &AuthenticatedRequest,
        expires_at: &str,
    ) -> HeaderValue {
        let canonical = spark_contracts::user_presence_canonical(
            &request.method,
            &request.path_and_query,
            &request.timestamp,
            &request.nonce,
            &request.content_sha256,
            &request.device_id,
            expires_at,
            &request.node_id,
        );
        let signature: p256::ecdsa::Signature = key.sign(canonical.as_bytes());
        let proof = spark_contracts::UserPresenceHeader {
            version: spark_contracts::USER_PRESENCE_PROOF_VERSION,
            expires_at: expires_at.into(),
            signature: crate::crypto::base64url_encode(&signature.to_bytes()),
        };
        HeaderValue::from_str(&crate::crypto::base64url_encode(
            &serde_json::to_vec(&proof).unwrap(),
        ))
        .unwrap()
    }

    fn spki(key: &p256::ecdsa::SigningKey) -> Vec<u8> {
        key.verifying_key()
            .to_public_key_der()
            .unwrap()
            .as_bytes()
            .to_vec()
    }

    fn now() -> OffsetDateTime {
        OffsetDateTime::parse("2026-08-28T14:20:40Z", &Rfc3339).unwrap()
    }

    #[test]
    fn valid_proof_is_bound_to_every_authenticated_request_field() {
        let key = signing_key();
        let request = request();
        let proof = encoded_proof(&key, &request, "2026-08-28T14:21:00Z");
        assert_eq!(
            verify(Some(&proof), Some(&spki(&key)), &request, now()),
            Ok(())
        );

        let mutations = [
            AuthenticatedRequest {
                node_id: uuid::Uuid::from_u128(3),
                ..request.clone()
            },
            AuthenticatedRequest {
                method: "POST".into(),
                ..request.clone()
            },
            AuthenticatedRequest {
                path_and_query: "/api/v1/devices/another".into(),
                ..request.clone()
            },
            AuthenticatedRequest {
                timestamp: "2026-08-28T14:20:31Z".into(),
                ..request.clone()
            },
            AuthenticatedRequest {
                nonce: "different".into(),
                ..request.clone()
            },
            AuthenticatedRequest {
                content_sha256: "0".repeat(64),
                ..request.clone()
            },
            AuthenticatedRequest {
                device_id: uuid::Uuid::nil(),
                ..request
            },
        ];
        for mutated in mutations {
            assert_eq!(
                verify(Some(&proof), Some(&spki(&key)), &mutated, now()),
                Err(PresenceError::Invalid)
            );
        }
    }

    #[test]
    fn missing_unregistered_expired_and_overlong_proofs_fail_closed() {
        let key = signing_key();
        let request = request();
        assert_eq!(
            verify(None, Some(&spki(&key)), &request, now()),
            Err(PresenceError::Required)
        );
        let valid = encoded_proof(&key, &request, "2026-08-28T14:21:00Z");
        assert_eq!(
            verify(Some(&valid), None, &request, now()),
            Err(PresenceError::NotRegistered)
        );
        let expired = encoded_proof(&key, &request, "2026-08-28T14:20:35Z");
        assert_eq!(
            verify(Some(&expired), Some(&spki(&key)), &request, now()),
            Err(PresenceError::Expired)
        );
        let overlong = encoded_proof(&key, &request, "2026-08-28T14:22:00Z");
        assert_eq!(
            verify(Some(&overlong), Some(&spki(&key)), &request, now()),
            Err(PresenceError::Invalid)
        );
    }

    #[test]
    fn legacy_presence_version_is_refused() {
        let key = signing_key();
        let request = request();
        let proof = encoded_proof(&key, &request, "2026-08-28T14:21:00Z");
        let decoded = base64url_decode(proof.to_str().unwrap()).unwrap();
        let mut legacy: spark_contracts::UserPresenceHeader =
            serde_json::from_slice(&decoded).unwrap();
        legacy.version = 1;
        let header = HeaderValue::from_str(&crate::crypto::base64url_encode(
            &serde_json::to_vec(&legacy).unwrap(),
        ))
        .unwrap();
        assert_eq!(
            verify(Some(&header), Some(&spki(&key)), &request, now()),
            Err(PresenceError::Invalid)
        );
    }

    #[test]
    fn malformed_or_wrong_key_proof_is_invalid() {
        let key = signing_key();
        let request = request();
        let malformed = HeaderValue::from_static("not-base64url!");
        assert_eq!(
            verify(Some(&malformed), Some(&spki(&key)), &request, now()),
            Err(PresenceError::Invalid)
        );
        let proof = encoded_proof(&key, &request, "2026-08-28T14:21:00Z");
        let other_key = p256::ecdsa::SigningKey::from_slice(&[9; 32]).unwrap();
        assert_eq!(
            verify(Some(&proof), Some(&spki(&other_key)), &request, now()),
            Err(PresenceError::Invalid)
        );
    }

    #[test]
    fn future_request_timestamp_cannot_extend_server_freshness_window() {
        let key = signing_key();
        let request = AuthenticatedRequest {
            timestamp: "2026-08-28T14:22:30Z".into(),
            ..request()
        };
        let proof = encoded_proof(&key, &request, "2026-08-28T14:23:30Z");

        assert_eq!(
            verify(Some(&proof), Some(&spki(&key)), &request, now()),
            Err(PresenceError::Invalid)
        );
    }
}
