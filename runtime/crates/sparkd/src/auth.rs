//! Authenticate SPARK2 request timestamps, per-device nonces, body digests and paired P-256 signatures.

use axum::body::{Body, Bytes, to_bytes};
use axum::extract::{Request, State};
use axum::http::StatusCode;
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use p256::ecdsa::signature::{Signer as _, Verifier as _};
use p256::pkcs8::DecodePublicKey;
use time::OffsetDateTime;

use crate::crypto::{base64url_decode, sha256_hex};
use crate::state::AppState;
use crate::store;

pub const HEADER_NODE_ID: &str = "x-spark-node-id";
pub const HEADER_DEVICE_ID: &str = "x-spark-device-id";
pub const HEADER_TIMESTAMP: &str = "x-spark-timestamp";
pub const HEADER_NONCE: &str = "x-spark-nonce";
pub const HEADER_CONTENT_SHA256: &str = "x-spark-content-sha256";
pub const HEADER_SIGNATURE: &str = "x-spark-signature";
pub const HEADER_USER_PRESENCE: &str = "x-spark-user-presence";
/// Request-signing protocols this runtime accepts, advertised on health and identity so clients can detect a mismatch.
pub const AUTH_PROTOCOLS: [&str; 1] = ["SPARK2"];

pub const TIMESTAMP_TOLERANCE_SECONDS: i64 = 120;
pub const NONCE_RETENTION_SECONDS: i64 = 600;
const MAX_BODY_BYTES: usize = 16 * 1024 * 1024;

/// Authorised caller, available to handlers via `axum::extract::Extension`.
#[derive(Debug, Clone)]
pub struct Principal {
    pub device_id: uuid::Uuid,
    pub role: String,
    pub access_authentication: AccessAuthentication,
    /// Consume single-use presence proofs only when the authorized operation actually requires presence.
    pub user_presence: Option<String>,
}

/// Report the authenticated request credential without inferring its network transport.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccessAuthentication {
    DeviceSignature,
    OptionalServiceToken,
}

impl AccessAuthentication {
    pub fn api_name(self) -> &'static str {
        match self {
            Self::DeviceSignature => "device_signature",
            Self::OptionalServiceToken => "optional_service_token",
        }
    }
}

/// Exact bytes whose digest and signature the middleware verified.
#[derive(Debug, Clone)]
pub struct AuthenticatedBody(pub Bytes);

/// Bind elevated proofs to request values already verified by SPARK2, without re-trusting handler headers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthenticatedRequest {
    pub method: String,
    pub path_and_query: String,
    pub timestamp: String,
    pub nonce: String,
    pub content_sha256: String,
    pub device_id: uuid::Uuid,
    pub node_id: uuid::Uuid,
}

impl Principal {
    pub fn is_admin(&self) -> bool {
        matches!(self.role.as_str(), "owner" | "administrator")
    }
}

#[derive(Debug)]
enum AuthOutcome {
    Ok {
        principal: Principal,
        request: Box<AuthenticatedRequest>,
    },
    Unpaired,
    ProtocolUnsupported,
    SignatureInvalid,
    ClockSkew,
    Replayed(uuid::Uuid),
    BodyMismatch,
    StorageFailure,
}

fn error_response(outcome: &AuthOutcome) -> Response {
    let (status, code) = match outcome {
        AuthOutcome::Unpaired => (StatusCode::UNAUTHORIZED, "DEVICE_NOT_PAIRED"),
        AuthOutcome::ProtocolUnsupported => (StatusCode::UNAUTHORIZED, "PROTOCOL_UNSUPPORTED"),
        AuthOutcome::SignatureInvalid | AuthOutcome::BodyMismatch => {
            (StatusCode::UNAUTHORIZED, "SIGNATURE_INVALID")
        }
        AuthOutcome::ClockSkew => (StatusCode::UNAUTHORIZED, "CLOCK_SKEW_TOO_LARGE"),
        AuthOutcome::Replayed(_) => (StatusCode::CONFLICT, "REQUEST_REPLAYED"),
        AuthOutcome::StorageFailure => (StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL_ERROR"),
        AuthOutcome::Ok { .. } => unreachable!(),
    };
    let message = match outcome {
        AuthOutcome::ProtocolUnsupported => {
            "This Spark requires SPARK2 request signing. Update the app or the Spark runtime so both use the same version."
        }
        _ => code,
    };
    (
        status,
        axum::Json(serde_json::json!({
            "error": {
                "code": code,
                "message": message,
                "request_id": crate::route::current_request_id(),
                "details": { "supported_auth_protocols": AUTH_PROTOCOLS },
            }
        })),
    )
        .into_response()
}

/// Bind the trusted recipient node UUID as SPARK2's eighth canonical line.
pub fn canonical(
    method: &str,
    path_and_query: &str,
    timestamp: &str,
    nonce: &str,
    content_sha256: &str,
    device_id: &uuid::Uuid,
    node_id: &uuid::Uuid,
) -> String {
    format!(
        "SPARK2\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        method.to_uppercase(),
        path_and_query,
        timestamp,
        nonce,
        content_sha256,
        device_id,
        node_id
    )
}

fn path_and_query(request: &Request) -> String {
    let path = request.uri().path().to_owned();
    match request.uri().query() {
        Some(query) => format!("{path}?{query}"),
        None => path,
    }
}

pub async fn require_authentication(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Response {
    // Verify the consumed body's digest before rebuilding the handler request.
    let (parts, body) = request.into_parts();
    let body_bytes = match to_bytes(body, MAX_BODY_BYTES).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(&AuthOutcome::SignatureInvalid),
    };
    let request = Request::from_parts(parts, Body::from(body_bytes.clone()));

    let outcome = authenticate(&state, &request, &body_bytes);

    match outcome {
        AuthOutcome::Ok {
            principal,
            request: authenticated_request,
        } => {
            let router_principal = principal.role == crate::pool_router_identity::ROLE;
            if router_principal
                && (principal.access_authentication != AccessAuthentication::DeviceSignature
                    || !crate::pool_router_identity::allowed_route(
                        &authenticated_request.method,
                        &authenticated_request.path_and_query,
                    ))
            {
                return (StatusCode::FORBIDDEN, axum::Json(serde_json::json!({"error":{"code":"POOL_ROUTER_SCOPE_FORBIDDEN","message":"Router authority is limited to approved pool requests"}}))).into_response();
            }
            let proof_request = authenticated_request.clone();
            let mut request = request;
            request.extensions_mut().insert(principal);
            request.extensions_mut().insert(*authenticated_request);
            request
                .extensions_mut()
                .insert(AuthenticatedBody(body_bytes));
            let mut response = next.run(request).await;
            if router_principal && let Some(tls) = &state.tls_fingerprint {
                let message = crate::pool_router_identity::response_message(
                    &proof_request,
                    response.status().as_u16(),
                    tls,
                );
                let proof = crate::crypto::base64url_encode(
                    &state.identity.signing_key().sign(&message).to_bytes(),
                );
                if let Ok(value) = proof.parse() {
                    response
                        .headers_mut()
                        .insert(crate::pool_router_identity::RESPONSE_PROOF, value);
                }
            }
            response
        }
        other => {
            if let AuthOutcome::Replayed(device_id) = &other
                && let Err(retry_after) = state.rate_limiter.admit(
                    crate::ratelimit::Subject::Device(*device_id),
                    crate::ratelimit::RateClass::AuthFailure,
                )
            {
                return crate::ratelimit::rate_limited(retry_after);
            }
            if let Some(response) = crate::ratelimit::reject_authentication_abuse(&state, &request)
            {
                return response;
            }
            record_rejection(&state, &request, &other);
            error_response(&other)
        }
    }
}

/// Publish rejected-authentication details only to administrators and label supplied device IDs as unverified claims.
fn record_rejection(state: &AppState, request: &Request, outcome: &AuthOutcome) {
    let (event_type, severity) = match outcome {
        AuthOutcome::Replayed(_) => ("security.replay.rejected", "warning"),
        AuthOutcome::Unpaired | AuthOutcome::ProtocolUnsupported => {
            ("security.signature.rejected", "notice")
        }
        _ => ("security.signature.rejected", "warning"),
    };
    let claimed_device = hv(request.headers(), HEADER_DEVICE_ID);
    let Some(database) = &state.database else {
        return;
    };
    let conn = database.lock();
    state.events.emit_scoped(
        Some(&conn),
        &state.identity.node_id().to_string(),
        None,
        event_type,
        severity,
        serde_json::json!({
            "claimed_device_id": claimed_device,
            "method": request.method().as_str(),
            "path": request.uri().path(),
            "reason": format!("{outcome:?}"),
        }),
        crate::events::Visibility::min_role(crate::capability::Role::Administrator),
    );
}

fn authenticate(state: &AppState, request: &Request, body_bytes: &Bytes) -> AuthOutcome {
    let h = request.headers();
    let access_authentication = AccessAuthentication::DeviceSignature;

    // A signed request without the node-id line comes from the previous protocol; name the mismatch instead of a generic failure.
    if hv(h, HEADER_SIGNATURE).is_some() && hv(h, HEADER_NODE_ID).is_none() {
        return AuthOutcome::ProtocolUnsupported;
    }
    let timestamp = match hv(h, HEADER_TIMESTAMP) {
        Some(v) => v,
        None => return AuthOutcome::SignatureInvalid,
    };
    let parsed_ts =
        match OffsetDateTime::parse(&timestamp, &time::format_description::well_known::Rfc3339) {
            Ok(ts) => ts,
            Err(_) => return AuthOutcome::ClockSkew,
        };
    let now = OffsetDateTime::now_utc();
    if ((now - parsed_ts).whole_seconds()).abs() > TIMESTAMP_TOLERANCE_SECONDS {
        return AuthOutcome::ClockSkew;
    }

    let node_id = state.identity.node_id();
    if hv(h, HEADER_NODE_ID).as_deref() != Some(node_id.to_string().as_str()) {
        return AuthOutcome::SignatureInvalid;
    }
    let device_id = match hv(h, HEADER_DEVICE_ID).and_then(|v| uuid::Uuid::parse_str(&v).ok()) {
        Some(id) => id,
        None => return AuthOutcome::SignatureInvalid,
    };
    let nonce = match hv(h, HEADER_NONCE) {
        Some(v) => v,
        None => return AuthOutcome::SignatureInvalid,
    };
    let content_sha256 = match hv(h, HEADER_CONTENT_SHA256) {
        Some(v) => v,
        None => return AuthOutcome::SignatureInvalid,
    };
    let signature_b64 = match hv(h, HEADER_SIGNATURE) {
        Some(v) => v,
        None => return AuthOutcome::SignatureInvalid,
    };

    let device = {
        let db = match &state.database {
            Some(db) => db,
            None => return AuthOutcome::Unpaired,
        };
        let conn = db.lock();
        match store::load_device_by_id(&conn, &device_id) {
            Ok(Some(device)) => device,
            Ok(None) => match crate::pool_router_identity::load_principal(&conn, device_id) {
                Ok(Some(router)) => router,
                Ok(None) => return AuthOutcome::Unpaired,
                Err(_) => return AuthOutcome::StorageFailure,
            },
            Err(_) => return AuthOutcome::Unpaired,
        }
    };

    let actual_digest = sha256_hex(body_bytes);
    if actual_digest != content_sha256 {
        return AuthOutcome::BodyMismatch;
    }

    let authenticated_path = path_and_query(request);
    let canonical_bytes = canonical(
        request.method().as_str(),
        &authenticated_path,
        &timestamp,
        &nonce,
        &content_sha256,
        &device_id,
        &node_id,
    )
    .into_bytes();

    let signature_bytes = match base64url_decode(&signature_b64) {
        Ok(b) => b,
        Err(_) => return AuthOutcome::SignatureInvalid,
    };
    let signature = match p256::ecdsa::Signature::from_slice(&signature_bytes) {
        Ok(s) => s,
        Err(_) => return AuthOutcome::SignatureInvalid,
    };
    let verifying_key =
        match p256::ecdsa::VerifyingKey::from_public_key_der(&device.public_key_spki) {
            Ok(k) => k,
            Err(_) => return AuthOutcome::SignatureInvalid,
        };
    if verifying_key.verify(&canonical_bytes, &signature).is_err() {
        return AuthOutcome::SignatureInvalid;
    }

    let nonce_hash = sha256_hex(nonce.as_bytes()).into_bytes();
    let admitted_at = OffsetDateTime::now_utc();
    let expiry = admitted_at + time::Duration::seconds(NONCE_RETENTION_SECONDS);
    if let Some(db) = &state.database {
        let mut conn = db.lock();
        let admitted_at = admitted_at
            .format(&time::format_description::well_known::Rfc3339)
            .expect("RFC3339");
        let expiry = expiry
            .format(&time::format_description::well_known::Rfc3339)
            .expect("RFC3339");
        let admission = if device.role == crate::pool_router_identity::ROLE {
            crate::pool_router_identity::admit_nonce(
                &mut conn,
                device_id,
                &nonce_hash,
                &admitted_at,
                &expiry,
            )
        } else {
            store::admit_request_nonce(&mut conn, &device_id, &nonce_hash, &admitted_at, &expiry)
        };
        match admission {
            Ok(store::NonceAdmission::Admitted) => {}
            Ok(store::NonceAdmission::Replayed) => return AuthOutcome::Replayed(device_id),
            Err(error) => {
                tracing::error!(%error, "request nonce admission failed");
                return AuthOutcome::StorageFailure;
            }
        }
    }

    AuthOutcome::Ok {
        principal: Principal {
            device_id,
            role: guest_aware_role(state, &device_id, device.role),
            access_authentication,
            user_presence: hv(h, HEADER_USER_PRESENCE),
        },
        request: Box::new(AuthenticatedRequest {
            method: request.method().as_str().to_uppercase(),
            path_and_query: authenticated_path,
            timestamp,
            nonce,
            content_sha256,
            device_id,
            node_id,
        }),
    }
}

/// Hold a device at guest while it holds a guest grant; a lookup this daemon cannot answer fails closed to guest rather than to the stored role.
fn guest_aware_role(state: &AppState, device_id: &uuid::Uuid, stored: String) -> String {
    let Some(database) = &state.database else {
        return crate::capability::Role::Guest.name().to_owned();
    };
    let parsed = crate::capability::Role::parse(&stored);
    match crate::guest::effective_role(&database.lock(), device_id, parsed) {
        Ok(Some(role)) => role.name().to_owned(),
        Ok(None) => stored,
        Err(error) => {
            tracing::error!(%error, "guest grant lookup failed; holding the device at guest");
            crate::capability::Role::Guest.name().to_owned()
        }
    }
}

fn hv(h: &axum::http::HeaderMap, name: &str) -> Option<String> {
    h.get(name)
        .and_then(|v| v.to_str().ok())
        .map(ToOwned::to_owned)
}
