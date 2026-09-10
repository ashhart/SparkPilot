//! Expose pairing and role-gated device management with shared typed error envelopes.

use axum::extract::{Extension, Path, State};

use axum::http::{HeaderMap, StatusCode};

use axum::response::Json;

use p256::ecdsa::signature::Verifier as _;

use serde_json::{Value, json};

use crate::auth::{AuthenticatedRequest, Principal};

use crate::idempotency::{IdempotencyRequest, StoredResponse, json_response};

use crate::pairing::{self, ChallengeRequest, ClaimRequest, PairingError};

use crate::state::AppState;

use crate::store::StoreError;

pub(crate) type HandlerResult<T> = Result<T, (StatusCode, Json<Value>)>;

pub(crate) fn error_envelope(code: &str, request_id: &str) -> Json<Value> {
    Json(json!({
        "error": { "code": code, "message": code, "request_id": request_id }
    }))
}

/// A 422 with a specific code, for input the contract rejects outright.
fn unprocessable(code: &str, message: &str) -> (StatusCode, Json<Value>) {
    (
        StatusCode::UNPROCESSABLE_ENTITY,
        Json(json!({
            "error": {
                "code": code,
                "message": message,
                "request_id": crate::route::current_request_id(),
            }
        })),
    )
}

pub(crate) fn internal_error() -> (StatusCode, Json<Value>) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        error_envelope("INTERNAL_ERROR", &uuid::Uuid::new_v4().to_string()),
    )
}

mod observation;
pub use observation::{capabilities, health, identity, status};

mod pairing_routes;
use pairing_routes::pairing_error_response;
pub use pairing_routes::{
    CreateInvitationRequest, PairingJoinPackage, RedeemJoinCodeRequest, create_invitation,
    pairing_challenge, pairing_claim, presence_challenge, redeem_join_code,
};

mod device_management;
pub use device_management::{list_devices, update_device};

mod presence_keys;
pub use presence_keys::{EnrollPresenceKeyRequest, enroll_presence_key};

mod device_revocation;
pub use device_revocation::revoke_device;
