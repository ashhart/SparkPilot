use super::*;

/// `GET /api/v1/remote/overlay/setup` — the helper's live Tailscale state, including the owner's sign-in link while an enable waits for it.
pub async fn get_overlay_setup(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    owner_only(&principal)?;
    let Some(remote) = state.remote.clone() else {
        return Err(internal_envelope("remote access service unavailable"));
    };
    let setup = tokio::task::spawn_blocking(move || remote.overlay_setup())
        .await
        .map_err(|_| internal_envelope("overlay setup probe stopped"))?
        .map_err(|error| internal_envelope(&error.to_string()))?;
    Ok(Json(serde_json::to_value(setup).unwrap()))
}
