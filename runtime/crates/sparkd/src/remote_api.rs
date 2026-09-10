//! Expose owner-only remote status and durable enable/disable operations completed by workers.

use axum::extract::{Extension, State};

use axum::http::{HeaderMap, StatusCode};

use axum::response::Json;

use serde_json::{Value, json};

use crate::auth::{AuthenticatedRequest, Principal};

use crate::idempotency::{IdempotencyRequest, json_response};

use crate::preview::{
    PreviewBinding, PreviewConsequences, PreviewDraft, PreviewEvidence, PreviewMessage,
    PreviewRemoteEvidence, action_key, target_and_cluster,
};

use crate::state::AppState;

const REMOTE_RESOURCE: &str = "remote-access";

mod preferences;
pub use preferences::{configure_overlay_preferences, get_overlay_preferences};

const ENABLE_ROUTE: &str = "/api/v1/remote/enable";

const DISABLE_ROUTE: &str = "/api/v1/remote/disable";

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RemotePreviewBody {
    pub mode: String,
}

fn internal_envelope(detail: &str) -> (StatusCode, Json<Value>) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({
            "error": { "code": "INTERNAL", "message": detail, "request_id": crate::route::current_request_id() }
        })),
    )
}

fn error_envelope(status: StatusCode, code: &str, message: &str) -> (StatusCode, Json<Value>) {
    (
        status,
        Json(json!({
            "error": {
                "code": code,
                "message": message,
                "request_id": crate::route::current_request_id(),
            }
        })),
    )
}

fn append_refusal(
    state: &AppState,
    principal: &Principal,
    idempotency: &IdempotencyRequest,
    route: &str,
    action: &str,
    reason_code: &str,
) -> Result<(), (StatusCode, Json<Value>)> {
    crate::audit::append_refusal(
        state
            .database
            .as_ref()
            .ok_or_else(|| internal_envelope("no database"))?,
        state.clock.as_ref(),
        principal.device_id,
        &principal.role,
        route,
        action,
        Some(REMOTE_RESOURCE),
        idempotency.request_id,
        reason_code,
    )
    .map(|_| ())
    .map_err(crate::audit::unavailable_envelope)
}

fn presence_key(
    state: &AppState,
    principal: &Principal,
) -> Result<Option<Vec<u8>>, (StatusCode, Json<Value>)> {
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("no database"))?;
    let connection = database.lock();
    crate::store::load_presence_key_by_device_id(&connection, &principal.device_id)
        .map_err(|error| internal_envelope(&error.to_string()))
}

/// Refuse every non-owner before any remote state is read, as every other `/api/v1/remote/*` route does.
pub(super) fn owner_only(principal: &Principal) -> Result<(), (StatusCode, Json<Value>)> {
    if principal.role != "owner" {
        return Err(error_envelope(
            StatusCode::FORBIDDEN,
            "ROLE_FORBIDDEN",
            "remote access is owner-only",
        ));
    }
    Ok(())
}

/// `GET /api/v1/remote` — the `RemoteStatus` document, owner-only as this module's own contract says.
pub async fn get_remote_status(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    owner_only(&principal)?;
    let Some(remote) = state.remote.clone() else {
        return Err(internal_envelope("remote access service unavailable"));
    };
    let row = tokio::task::spawn_blocking(move || remote.status())
        .await
        .map_err(|_| internal_envelope("remote status probe stopped"))?
        .map_err(|error| internal_envelope(&error.to_string()))?;
    Ok(Json(serde_json::to_value(row).unwrap()))
}

/// Reconcile transport health on owner demand between thirty-second ticks; no mode change or fresh presence is needed.
pub async fn refresh_remote_status(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    owner_only(&principal)?;
    let Some(remote) = state.remote.clone() else {
        return Err(internal_envelope("remote access service unavailable"));
    };
    let row = tokio::task::spawn_blocking(move || remote.refresh_health())
        .await
        .map_err(|_| internal_envelope("remote health refresh stopped"))?
        .map_err(|error| internal_envelope(&error.to_string()))?;
    Ok(Json(serde_json::to_value(row).unwrap()))
}

mod enable;
use enable::remote_draft;
pub use enable::{EnableRemoteBody, enable_remote_access, preview_enable_remote_access};

mod disable;
pub use disable::{DisableRemoteBody, disable_remote_access, preview_disable_remote_access};

mod overlay;
pub use overlay::get_overlay_setup;
