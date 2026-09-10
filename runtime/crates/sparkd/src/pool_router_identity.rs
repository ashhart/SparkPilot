//! Distinct runtime signing keys and owner-anchored recipient enrollment.
use crate::{
    auth::Principal,
    crypto::{base64url_decode, base64url_encode, sha256_hex},
    pool::{self, PoolError},
    pool_router_contracts::*,
    state::AppState,
};

use p256::{
    ecdsa::{
        Signature, SigningKey, VerifyingKey,
        signature::{Signer, Verifier},
    },
    pkcs8::{DecodePublicKey, EncodePublicKey},
};

use rusqlite::{Connection, OptionalExtension, params};

use serde::{Deserialize, Serialize};

use serde_json::{Value, json};

use std::{
    io::{Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::PathBuf,
};

use uuid::Uuid;

use zeroize::Zeroize;

pub const ROLE: &str = "pool_router";

pub const RESPONSE_PROOF: &str = "x-spark-router-authority-proof";

fn reject<T>(code: &'static str) -> Result<T, PoolError> {
    pool::refuse(code)
}

fn io(_: std::io::Error) -> PoolError {
    PoolError::Refused("POOL_ROUTER_KEY_UNAVAILABLE")
}

pub fn load_principal(
    conn: &Connection,
    id: Uuid,
) -> Result<Option<crate::store::DeviceRow>, rusqlite::Error> {
    let exists: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='pool_router_principals')",
        [],
        |r| r.get(0),
    )?;
    if !exists {
        return Ok(None);
    }
    conn.query_row("SELECT display_name,request_public_key_spki FROM pool_router_principals WHERE principal_id=?1 AND revoked=0 AND EXISTS(SELECT 1 FROM devices WHERE id=enrolled_by_device_id AND revoked_at IS NULL AND role='owner')",[id.to_string()],|r|Ok(crate::store::DeviceRow{id,display_name:r.get(0)?,role:ROLE.into(),public_key_spki:r.get(1)?})).optional()
}

pub fn admit_nonce(
    conn: &mut Connection,
    id: Uuid,
    hash: &[u8],
    now: &str,
    expiry: &str,
) -> Result<crate::store::NonceAdmission, crate::store::StoreError> {
    let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    tx.execute("DELETE FROM pool_router_nonces WHERE expires_at<=?1", [now])?;
    if load_principal(&tx, id)?.is_none() {
        return Err(crate::store::StoreError::NotFound("pool router"));
    }
    let count: u32 = tx.query_row(
        "SELECT count(*) FROM pool_router_nonces WHERE principal_id=?1",
        [id.to_string()],
        |r| r.get(0),
    )?;
    if count >= 8192 {
        return Err(crate::store::StoreError::Audit(
            "router nonce capacity exceeded".into(),
        ));
    }
    let changed=tx.execute("INSERT INTO pool_router_nonces VALUES(?1,?2,?3) ON CONFLICT(principal_id,nonce_hash) DO NOTHING",params![id.to_string(),hash,expiry])?;
    tx.commit()?;
    Ok(if changed == 1 {
        crate::store::NonceAdmission::Admitted
    } else {
        crate::store::NonceAdmission::Replayed
    })
}

pub fn allowed_route(method: &str, path: &str) -> bool {
    if path.contains('?') {
        return false;
    }
    if method == "GET"
        && matches!(
            path,
            "/api/v1/inference/pools" | "/api/v1/inference/node-capabilities"
        )
    {
        return true;
    }
    if method == "POST" && path == "/api/v1/inference/reservations" {
        return true;
    }
    let Some(suffix) = path.strip_prefix("/api/v1/inference/reservations/") else {
        return false;
    };
    let mut parts = suffix.split('/');
    if parts.next().and_then(|v| Uuid::parse_str(v).ok()).is_none() {
        return false;
    }
    matches!(
        (method, parts.next(), parts.next()),
        ("GET", None, None) | ("POST", Some("execute" | "cancel"), None)
    )
}

pub fn response_message(
    auth: &crate::auth::AuthenticatedRequest,
    status: u16,
    tls: &str,
) -> Vec<u8> {
    format!(
        "SPARK-POOL-RESPONSE-1\n{}\n{status}\n{tls}",
        sha256_hex(
            crate::auth::canonical(
                &auth.method,
                &auth.path_and_query,
                &auth.timestamp,
                &auth.nonce,
                &auth.content_sha256,
                &auth.device_id,
                &auth.node_id
            )
            .as_bytes()
        )
    )
    .into_bytes()
}

pub fn verify_response(
    public: &str,
    fingerprint: &str,
    auth: &crate::auth::AuthenticatedRequest,
    status: u16,
    tls: &str,
    proof: &str,
) -> Result<(), PoolError> {
    verify_authority(
        public,
        fingerprint,
        &response_message(auth, status, tls),
        proof,
    )
}

pub fn read_authority(
    state: &AppState,
    principal: &Principal,
) -> Result<(), (axum::http::StatusCode, axum::Json<Value>)> {
    state
        .require(principal, crate::capability::Capability::InferencePoolRoute)
        .resource("inference.pools")
        .check()
}

pub fn granted_deployments(
    conn: &Connection,
    id: Uuid,
    now: i64,
) -> Result<std::collections::HashSet<String>, PoolError> {
    let mut result = std::collections::HashSet::new();
    let mut statement = conn.prepare(
        "SELECT grant_json FROM inference_router_grants WHERE revoked=0 AND expires_at>?1",
    )?;
    let rows = statement.query_map([now], |r| r.get::<_, String>(0))?;
    for row in rows {
        let grant: crate::pool_contracts::RouterGrant = serde_json::from_str(&row?)?;
        if grant.scope.router_device_id != id || grant.issued_at > now {
            continue;
        }
        let policy = pool::load_policy(conn, grant.scope.pool_id)?;
        if policy.paused
            || policy.revision != grant.scope.policy_revision
            || !policy.router_device_ids.contains(&id)
            || pool::eligible_device(conn, grant.scope.caller_device_id).is_err()
            || pool::eligible_owner(conn, grant.issued_by_device_id).is_err()
        {
            continue;
        }
        result.extend(grant.scope.deployment_ids);
    }
    Ok(result)
}

/// Retain old principals after reenrollment because local key rotation cannot prove the destination retired a copied key.
pub fn peer_inventory(conn: &Connection, current: Uuid) -> Result<RouterPeerInventory, PoolError> {
    let mut statement = conn.prepare("SELECT trust_json,principal_id,approved_at FROM pool_router_peers ORDER BY node_id,approved_at,principal_id")?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
        ))
    })?;
    let mut peers = Vec::new();
    for row in rows {
        let (trust, principal, approved_at) = row?;
        let principal_id = Uuid::parse_str(&principal)
            .map_err(|_| PoolError::Refused("POOL_STORAGE_UNAVAILABLE"))?;
        let uses_current_key = principal_id == current;
        peers.push(RouterPeerRecord {
            recipient: serde_json::from_str(&trust)?,
            principal_id,
            approved_at,
            uses_current_key,
            recipient_retirement: if uses_current_key {
                RouterRecipientRetirement::NotRequested
            } else {
                RouterRecipientRetirement::Unconfirmed
            },
        });
    }
    Ok(RouterPeerInventory {
        current_principal_id: current,
        peers,
    })
}

mod router_keys;
pub use router_keys::{RouterIdentityService, RouterKey, challenge_message};
use router_keys::{identity_message, message};

mod enrollment;
use enrollment::verify_authority;
pub use enrollment::{
    create_challenge, enroll, prove, revoke, validate_proof_request, verify_authority_anchor,
    verify_identity,
};
