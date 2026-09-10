//! Authenticate a six-digit code with SPAKE2 before disclosing the pinned invitation. Every exchange spends the shared guessing budget, even when the client never returns.
use aws_lc_rs::aead;
use axum::{Json, extract::State, http::StatusCode};
use base64::{Engine, engine::general_purpose::STANDARD};
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::{
    handlers::{HandlerResult, error_envelope, internal_error},
    pairing,
    state::AppState,
};

const CLIENT: &[u8] = b"SparkPilot pairing v2 client";
const SERVER: &[u8] = b"SparkPilot pairing v2 server";
const SEAL: &[u8] = b"spark-pairing-seal-v2";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ExchangeRequest {
    message: String,
}

#[derive(Serialize)]
pub(crate) struct ExchangeResponse {
    message: String,
    sealed_package: String,
}

pub(crate) async fn exchange(
    State(state): State<AppState>,
    Json(request): Json<ExchangeRequest>,
) -> HandlerResult<Json<ExchangeResponse>> {
    let invalid = || {
        (
            StatusCode::BAD_REQUEST,
            error_envelope("INVALID_REQUEST", &uuid::Uuid::new_v4().to_string()),
        )
    };
    if request.message.len() != 44 {
        return Err(invalid());
    }
    let message = STANDARD.decode(&request.message).map_err(|_| invalid())?;
    if message.len() != 32 {
        return Err(invalid());
    }
    let tls = state.tls_fingerprint.clone().ok_or_else(internal_error)?;
    // Release the database mutex before curve arithmetic. Count all attempts so a wrong password cannot avoid the limiter by discarding the encrypted response.
    let (password, invitation) = {
        let guard = state.database.as_ref().ok_or_else(internal_error)?.lock();
        let window =
            crate::store::now_iso8601_minus_minutes(pairing::JOIN_CODE_FAILURE_WINDOW_MINUTES);
        let count = pairing::join_code_failures_in_window(&guard).map_err(|_| internal_error())?;
        if count >= pairing::MAX_FAILED_JOIN_CODES {
            return Err((
                StatusCode::TOO_MANY_REQUESTS,
                error_envelope("RATE_LIMITED", &uuid::Uuid::new_v4().to_string()),
            ));
        }
        guard
            .execute(
                "DELETE FROM join_code_attempts WHERE attempted_at < ?1",
                [&window],
            )
            .map_err(|_| internal_error())?;
        guard
            .execute(
                "INSERT INTO join_code_attempts (attempted_at) VALUES (?1)",
                [crate::store::now_iso8601()],
            )
            .map_err(|_| internal_error())?;
        // One current code per Spark: the most recently issued unconsumed invitation. No code-derived locator goes onto the wire, which would permit offline guessing.
        let row: Option<(Vec<u8>, String)> = guard.query_row(
            "SELECT join_code_hash, signed_payload_json FROM pairing_invitations WHERE join_code_hash IS NOT NULL AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at > ?1 ORDER BY issued_at DESC, rowid DESC LIMIT 1",
            [crate::store::now_iso8601()], |row| Ok((row.get(0)?,row.get(1)?))
        ).optional().map_err(|_| internal_error())?;
        row.ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                error_envelope("JOIN_CODE_INVALID", &uuid::Uuid::new_v4().to_string()),
            )
        })?
    };
    // The existing store represents the SHA-256 digest as 64 ASCII hex bytes.
    let password = Zeroizing::new(hex::decode(&password).map_err(|_| internal_error())?);
    if password.len() != 32 {
        return Err(internal_error());
    }
    let invitation: serde_json::Value =
        serde_json::from_str(&invitation).map_err(|_| internal_error())?;
    let package = serde_json::to_vec(&serde_json::json!({
        "node_name": state.identity.public.node_name,
        "tls_fingerprint": tls,
        "authority_public_key": state.identity.public.authority_public_key,
        "invitation": invitation
    }))
    .map_err(|_| internal_error())?;
    seal(&password, &message, &package)
        .map(Json)
        .map_err(|_| invalid())
}

struct Context(*mut aws_lc_sys::SPAKE2_CTX);
impl Drop for Context {
    fn drop(&mut self) {
        unsafe { aws_lc_sys::SPAKE2_CTX_free(self.0) };
    }
}

fn handshake(password: &[u8], peer: &[u8]) -> Result<([u8; 32], Zeroizing<[u8; 64]>), ()> {
    // AWS-LC provides the same BoringSSL SPAKE2 protocol used by the Apple client. Each context is local, used exactly once, and freed on every return path.
    let context = Context(unsafe {
        aws_lc_sys::SPAKE2_CTX_new(
            aws_lc_sys::spake2_role_t_spake2_role_bob,
            SERVER.as_ptr(),
            SERVER.len(),
            CLIENT.as_ptr(),
            CLIENT.len(),
        )
    });
    if context.0.is_null() {
        return Err(());
    }
    let mut message = [0u8; 32];
    let mut written = 0;
    if unsafe {
        aws_lc_sys::SPAKE2_generate_msg(
            context.0,
            message.as_mut_ptr(),
            &mut written,
            message.len(),
            password.as_ptr(),
            password.len(),
        )
    } != 1
        || written != 32
    {
        return Err(());
    }
    let mut key = Zeroizing::new([0u8; 64]);
    if unsafe {
        aws_lc_sys::SPAKE2_process_msg(
            context.0,
            key.as_mut_ptr(),
            &mut written,
            key.len(),
            peer.as_ptr(),
            peer.len(),
        )
    } != 1
        || written != 64
    {
        return Err(());
    }
    Ok((message, key))
}

fn seal(password: &[u8], peer: &[u8], package: &[u8]) -> Result<ExchangeResponse, ()> {
    let (message, key) = handshake(password, peer)?;
    let mut hash = Sha256::new();
    hash.update(SEAL);
    hash.update(key.as_ref());
    let key = Zeroizing::new(<[u8; 32]>::from(hash.finalize()));
    let cipher = aead::LessSafeKey::new(
        aead::UnboundKey::new(&aead::AES_256_GCM, key.as_ref()).map_err(|_| ())?,
    );
    let nonce: [u8; 12] = rand::random();
    let mut ciphertext = package.to_vec();
    cipher
        .seal_in_place_append_tag(
            aead::Nonce::assume_unique_for_key(nonce),
            aead::Aad::from(SEAL),
            &mut ciphertext,
        )
        .map_err(|_| ())?;
    let mut sealed = nonce.to_vec();
    sealed.extend_from_slice(&ciphertext);
    Ok(ExchangeResponse {
        message: STANDARD.encode(message),
        sealed_package: STANDARD.encode(sealed),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_invalid_peer_shares() {
        assert!(handshake(&[1; 32], &[]).is_err());
        assert!(handshake(&[1; 32], &[0; 31]).is_err());
        assert!(handshake(&[1; 32], &[0; 33]).is_err());
    }

    // Paired with the Swift test; all files contain generated test material only.
    #[test]
    fn apple_client_interoperates_with_runtime() {
        let Ok(directory) = std::env::var("SPARK_PAIRING_INTEROP_DIRECTORY") else {
            return;
        };
        let directory = std::path::PathBuf::from(directory);
        let client = directory.join("client");
        for _ in 0..600 {
            if client.exists() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        let message = std::fs::read(client).expect("Swift client share");
        let password = Sha256::digest(b"spark-pairing-join-code-v1:012345");
        let response =
            seal(&password, &message, b"Rust to Apple authenticated pairing").expect("seal");
        let staging = directory.join("response.tmp");
        std::fs::write(&staging, serde_json::to_vec(&response).unwrap()).unwrap();
        std::fs::rename(staging, directory.join("response")).unwrap();
    }
}
