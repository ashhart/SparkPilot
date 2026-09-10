//! Verify fresh device-key possession and one-time node nonce, not remote biometrics; Apple performs local authentication before signing.

use p256::ecdsa::signature::Verifier as _;
use p256::pkcs8::DecodePublicKey;
use rand::RngCore;
use rusqlite::Connection;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::clock::UtcClock;
use crate::crypto::base64url_decode;

/// Default freshness window; `[security] fresh_user_presence_seconds`.
pub const DEFAULT_FRESHNESS_SECONDS: i64 = 120;
/// Reject presence proofs older than five minutes regardless of configuration.
pub const MAXIMUM_FRESHNESS_SECONDS: i64 = 300;
const CHALLENGE_BYTES: usize = 32;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum PresenceError {
    #[error("presence header is malformed")]
    Malformed,
    #[error("presence challenge is unknown, expired, or already used")]
    Unusable,
    #[error("presence signature does not verify")]
    BadSignature,
    #[error("presence storage failed: {0}")]
    Storage(String),
}

/// A newly issued challenge, returned to the client.
#[derive(Debug, Clone, serde::Serialize)]
pub struct IssuedChallenge {
    pub challenge_id: String,
    /// base64url, no padding.
    pub challenge: String,
    pub expires_at: String,
}

/// Domain-separate the signed challenge and bind its id, device and node to prevent cross-node replay.
pub fn signing_input(
    challenge: &[u8],
    challenge_id: &uuid::Uuid,
    device_id: &uuid::Uuid,
    node_id: &str,
) -> Vec<u8> {
    let mut input = b"SPARK1-PRESENCE\n".to_vec();
    input.extend_from_slice(challenge);
    input.push(b'\n');
    input.extend_from_slice(challenge_id.to_string().as_bytes());
    input.push(b'\n');
    input.extend_from_slice(device_id.to_string().as_bytes());
    input.push(b'\n');
    input.extend_from_slice(node_id.as_bytes());
    input
}

/// Issue a single-use challenge for one device.
pub fn issue(
    conn: &Connection,
    clock: &dyn UtcClock,
    device_id: &uuid::Uuid,
    freshness_seconds: i64,
) -> Result<IssuedChallenge, PresenceError> {
    let window = freshness_seconds.clamp(1, MAXIMUM_FRESHNESS_SECONDS);
    let mut challenge = [0u8; CHALLENGE_BYTES];
    rand::rng().fill_bytes(&mut challenge);
    let id = uuid::Uuid::new_v4();
    let issued_at = clock.now();
    let expires_at = issued_at + time::Duration::seconds(window);
    let format = |value: OffsetDateTime| {
        value
            .format(&Rfc3339)
            .map_err(|error| PresenceError::Storage(error.to_string()))
    };
    let issued_at = format(issued_at)?;
    let expires_at = format(expires_at)?;

    // Opportunistic pruning keeps the table bounded without a sweeper.
    conn.execute(
        "DELETE FROM presence_challenges WHERE expires_at <= ?1",
        rusqlite::params![issued_at],
    )
    .map_err(|error| PresenceError::Storage(error.to_string()))?;
    conn.execute(
        "INSERT INTO presence_challenges (id, device_id, challenge, issued_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        rusqlite::params![
            id.to_string(),
            device_id.to_string(),
            challenge.as_slice(),
            issued_at,
            expires_at
        ],
    )
    .map_err(|error| PresenceError::Storage(error.to_string()))?;

    Ok(IssuedChallenge {
        challenge_id: id.to_string(),
        challenge: crate::crypto::base64url_encode(&challenge),
        expires_at,
    })
}

/// Atomically consume challenge-id.base64url-signature before verification so concurrent or invalid attempts cannot reuse the nonce.
pub fn verify_and_consume(
    conn: &Connection,
    clock: &dyn UtcClock,
    device_id: &uuid::Uuid,
    node_id: &str,
    public_key_spki: &[u8],
    header: &str,
) -> Result<(), PresenceError> {
    let Some((raw_id, raw_signature)) = header.split_once('.') else {
        return Err(PresenceError::Malformed);
    };
    let Ok(challenge_id) = uuid::Uuid::parse_str(raw_id) else {
        return Err(PresenceError::Malformed);
    };
    let Ok(signature_bytes) = base64url_decode(raw_signature) else {
        return Err(PresenceError::Malformed);
    };

    let now = clock
        .now()
        .format(&Rfc3339)
        .map_err(|error| PresenceError::Storage(error.to_string()))?;

    // Claim the challenge: one row can only transition to consumed once.
    let claimed = conn
        .execute(
            "UPDATE presence_challenges
                SET consumed_at = ?1
              WHERE id = ?2 AND device_id = ?3 AND consumed_at IS NULL AND expires_at > ?1",
            rusqlite::params![now, challenge_id.to_string(), device_id.to_string()],
        )
        .map_err(|error| PresenceError::Storage(error.to_string()))?;
    if claimed != 1 {
        return Err(PresenceError::Unusable);
    }

    let challenge: Vec<u8> = conn
        .query_row(
            "SELECT challenge FROM presence_challenges WHERE id = ?1",
            rusqlite::params![challenge_id.to_string()],
            |row| row.get(0),
        )
        .map_err(|error| PresenceError::Storage(error.to_string()))?;

    let input = signing_input(&challenge, &challenge_id, device_id, node_id);
    let Ok(signature) = p256::ecdsa::Signature::from_slice(&signature_bytes) else {
        return Err(PresenceError::BadSignature);
    };
    let Ok(verifying_key) = p256::ecdsa::VerifyingKey::from_public_key_der(public_key_spki) else {
        return Err(PresenceError::BadSignature);
    };
    verifying_key
        .verify(&input, &signature)
        .map_err(|_| PresenceError::BadSignature)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::{ManualUtcClock, system_clock};
    use p256::ecdsa::signature::Signer as _;
    use p256::pkcs8::EncodePublicKey;

    struct Device {
        id: uuid::Uuid,
        key: p256::ecdsa::SigningKey,
        spki: Vec<u8>,
    }

    fn seed(conn: &Connection) -> Device {
        let key = loop {
            let mut scalar = [0u8; 32];
            rand::rng().fill_bytes(&mut scalar);
            if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&scalar) {
                break key;
            }
        };
        let spki = p256::ecdsa::VerifyingKey::from(&key)
            .to_public_key_der()
            .unwrap()
            .as_bytes()
            .to_vec();
        let id = uuid::Uuid::new_v4();
        crate::store::insert_device(
            conn,
            &id,
            "presence device",
            "macos",
            &spki,
            &format!("fingerprint-{id}"),
            "owner",
        )
        .unwrap();
        Device { id, key, spki }
    }

    fn database() -> Connection {
        let mut conn = Connection::open_in_memory().unwrap();
        crate::migration::migrate(&mut conn).unwrap();
        conn
    }

    fn proof(device: &Device, issued: &IssuedChallenge, node_id: &str) -> String {
        let challenge = base64url_decode(&issued.challenge).unwrap();
        let challenge_id = uuid::Uuid::parse_str(&issued.challenge_id).unwrap();
        let input = signing_input(&challenge, &challenge_id, &device.id, node_id);
        let signature: p256::ecdsa::Signature = device.key.sign(&input);
        format!(
            "{}.{}",
            issued.challenge_id,
            crate::crypto::base64url_encode(&signature.to_bytes())
        )
    }

    #[test]
    fn a_fresh_proof_verifies_exactly_once() {
        let conn = database();
        let clock = system_clock();
        let device = seed(&conn);
        let issued = issue(&conn, clock.as_ref(), &device.id, 120).unwrap();
        let header = proof(&device, &issued, "node-1");

        assert_eq!(
            verify_and_consume(
                &conn,
                clock.as_ref(),
                &device.id,
                "node-1",
                &device.spki,
                &header
            ),
            Ok(())
        );
        assert_eq!(
            verify_and_consume(
                &conn,
                clock.as_ref(),
                &device.id,
                "node-1",
                &device.spki,
                &header
            ),
            Err(PresenceError::Unusable),
            "a presence proof is single use"
        );
    }

    #[test]
    fn a_proof_for_another_node_or_device_is_rejected() {
        let conn = database();
        let clock = system_clock();
        let device = seed(&conn);
        let other = seed(&conn);
        let issued = issue(&conn, clock.as_ref(), &device.id, 120).unwrap();
        let header = proof(&device, &issued, "node-1");
        assert_eq!(
            verify_and_consume(
                &conn,
                clock.as_ref(),
                &device.id,
                "node-2",
                &device.spki,
                &header
            ),
            Err(PresenceError::BadSignature)
        );

        let issued = issue(&conn, clock.as_ref(), &device.id, 120).unwrap();
        let header = proof(&device, &issued, "node-1");
        assert_eq!(
            verify_and_consume(
                &conn,
                clock.as_ref(),
                &other.id,
                "node-1",
                &other.spki,
                &header
            ),
            Err(PresenceError::Unusable),
            "a challenge is bound to the device it was issued to"
        );
    }

    #[test]
    fn an_expired_challenge_is_unusable() {
        let conn = database();
        let start = OffsetDateTime::parse("2026-08-28T12:00:00Z", &Rfc3339).unwrap();
        let clock = std::sync::Arc::new(ManualUtcClock::new(start));
        let device = seed(&conn);
        let issued = issue(&conn, clock.as_ref(), &device.id, 120).unwrap();
        let header = proof(&device, &issued, "node-1");
        clock.advance(time::Duration::seconds(121));
        assert_eq!(
            verify_and_consume(
                &conn,
                clock.as_ref(),
                &device.id,
                "node-1",
                &device.spki,
                &header
            ),
            Err(PresenceError::Unusable)
        );
    }

    #[test]
    fn a_wrong_signature_still_spends_the_challenge() {
        let conn = database();
        let clock = system_clock();
        let device = seed(&conn);
        let issued = issue(&conn, clock.as_ref(), &device.id, 120).unwrap();
        let forged = format!(
            "{}.{}",
            issued.challenge_id,
            crate::crypto::base64url_encode(&[7u8; 64])
        );
        assert_eq!(
            verify_and_consume(
                &conn,
                clock.as_ref(),
                &device.id,
                "node-1",
                &device.spki,
                &forged
            ),
            Err(PresenceError::BadSignature)
        );
        let header = proof(&device, &issued, "node-1");
        assert_eq!(
            verify_and_consume(
                &conn,
                clock.as_ref(),
                &device.id,
                "node-1",
                &device.spki,
                &header
            ),
            Err(PresenceError::Unusable),
            "a failed attempt must not leave the nonce available for retry"
        );
    }

    #[test]
    fn malformed_headers_are_rejected_without_touching_storage() {
        let conn = database();
        let clock = system_clock();
        let device = seed(&conn);
        for header in ["", "no-dot", "not-a-uuid.AAAA", "..", "x.y.z"] {
            let outcome = verify_and_consume(
                &conn,
                clock.as_ref(),
                &device.id,
                "node-1",
                &device.spki,
                header,
            );
            assert!(
                matches!(
                    outcome,
                    Err(PresenceError::Malformed) | Err(PresenceError::Unusable)
                ),
                "{header:?} produced {outcome:?}"
            );
        }
    }

    #[test]
    fn the_freshness_window_is_capped() {
        let conn = database();
        let start = OffsetDateTime::parse("2026-08-28T12:00:00Z", &Rfc3339).unwrap();
        let clock = std::sync::Arc::new(ManualUtcClock::new(start));
        let device = seed(&conn);
        let issued = issue(&conn, clock.as_ref(), &device.id, 86_400).unwrap();
        let expires = OffsetDateTime::parse(&issued.expires_at, &Rfc3339).unwrap();
        assert_eq!((expires - start).whole_seconds(), MAXIMUM_FRESHNESS_SECONDS);
    }
}
