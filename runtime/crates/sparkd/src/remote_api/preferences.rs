use super::*;
use crate::remote_overlay_setup::OverlayPreferenceChange;

const ROUTE: &str = "/api/v1/remote/overlay/preferences";

pub async fn get_overlay_preferences(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    owner_only(&principal)?;
    let remote = state.remote.ok_or_else(unavailable)?;
    let preferences = tokio::task::spawn_blocking(move || remote.overlay_preferences())
        .await
        .map_err(|_| unavailable())?
        .map_err(|_| unavailable())?;
    Ok(Json(
        serde_json::to_value(preferences).map_err(|_| unavailable())?,
    ))
}

pub async fn configure_overlay_preferences(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(change): Json<OverlayPreferenceChange>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    if let Err(error) = owner_only(&principal) {
        append_refusal(
            &state,
            &principal,
            &idempotency,
            ROUTE,
            "remote.configure",
            "ROLE_FORBIDDEN",
        )?;
        return Err(error);
    }
    if !change.is_valid() {
        return Err(error_envelope(
            StatusCode::UNPROCESSABLE_ENTITY,
            "TAILSCALE_SETTING_INVALID",
            "Change exactly one VPN or DNS setting.",
        ));
    }
    let remote = state.remote.clone().ok_or_else(unavailable)?;
    crate::appliance_api::enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        ROUTE,
        "remote.configure",
        serde_json::to_value(change).map_err(|_| unavailable())?,
        None,
        move |operation_id, lease| {
            let outcome = match remote.configure_overlay(operation_id, change) {
                Ok(preferences) => lease.succeed(&json!(preferences)),
                Err(_) => lease.fail("TAILSCALE_CHANGE_FAILED"),
            };
            if let Err(error) = outcome {
                tracing::error!(%error, "could not persist Tailscale preference outcome");
            }
        },
    )
    .await
}

fn unavailable() -> (StatusCode, Json<Value>) {
    error_envelope(
        StatusCode::SERVICE_UNAVAILABLE,
        "TAILSCALE_PREFERENCES_UNAVAILABLE",
        "The Spark's Tailscale settings could not be read; check its connection and runtime version.",
    )
}
