use super::*;

/// What the owner may change about a guest that has already joined.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub struct UpdateSharedAccess {
    /// Move the guest between pending, active and paused. Revocation has its own route.
    #[serde(default)]
    pub state: Option<String>,
    #[serde(default)]
    pub limits: Option<SharedAccessLimits>,
}

/// Confirm, pause or re-limit one guest. Every change needs the owner's fresh presence.
pub async fn update_shared_access(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    headers: HeaderMap,
    _idempotency: IdempotencyRequest,
    Path(device_id): Path<uuid::Uuid>,
    Json(request): Json<UpdateSharedAccess>,
) -> ApiResult<Json<Value>> {
    if request.state.is_none() && request.limits.is_none() {
        return Err(envelope(
            "PATCH_INVALID",
            "the change must set a state or new limits",
            StatusCode::UNPROCESSABLE_ENTITY,
        ));
    }
    let requested_state = match request.state.as_deref() {
        None => None,
        Some(name @ ("pending" | "active" | "paused")) => Some(GrantState::parse(name)),
        Some(_) => {
            return Err(envelope(
                "PATCH_INVALID",
                "state must be pending, active or paused; use revoke to withdraw access",
                StatusCode::UNPROCESSABLE_ENTITY,
            ));
        }
    };
    let existing = grant_of(&state, &device_id)?;
    if existing.policy.state == GrantState::Revoked {
        return Err(envelope(
            "GUEST_ACCESS_REVOKED",
            "that guest's access has already been withdrawn",
            StatusCode::CONFLICT,
        ));
    }
    let policy = match &request.limits {
        Some(limits) => {
            let policy = limits.policy(existing.policy.state);
            validated(&policy)?;
            Some(policy)
        }
        None => None,
    };
    owner_with_presence(
        &state,
        &principal,
        &authenticated,
        &headers,
        &format!("shared-access/{device_id}"),
        json!({
            "requested_state": request.state,
            "limits_changed": policy.is_some(),
        }),
    )?;

    let now = state.clock.now_rfc3339();
    {
        let database = state
            .database
            .as_ref()
            .ok_or_else(|| internal("no database"))?;
        let guard = database.lock();
        if let Some(policy) = &policy {
            crate::guest::update_policy(&guard, &device_id, policy, &now)
                .map_err(|error| internal(&error.to_string()))?;
        }
        if let Some(requested_state) = requested_state {
            crate::guest::set_grant_state(&guard, &device_id, requested_state, &now)
                .map_err(|error| internal(&error.to_string()))?;
        }
    }
    emit(&state, "shared_access.updated", &device_id, &now);
    let grant = grant_of(&state, &device_id)?;
    Ok(Json(json!({
        "device_id": device_id.to_string(),
        "display_name": grant.policy.display_name,
        "state": grant.policy.state.name(),
        "allowed_models": grant.policy.allowed_models,
        "allowed_hours": hours_json(&grant.policy.allowed_hours),
        "time_zone": grant.policy.time_zone,
        "max_concurrent_requests": grant.policy.max_concurrent_requests,
        "daily_token_budget": grant.policy.daily_token_budget,
        "expires_at": grant.policy.expires_at,
        "confirmed_at": grant.confirmed_at,
    })))
}

/// Withdraw a guest's access at once: the grant is revoked and the device grant with it.
pub async fn revoke_shared_access(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    headers: HeaderMap,
    _idempotency: IdempotencyRequest,
    Path(device_id): Path<uuid::Uuid>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let existing = grant_of(&state, &device_id)?;
    owner_with_presence(
        &state,
        &principal,
        &authenticated,
        &headers,
        &format!("shared-access/{device_id}"),
        json!({ "display_name": existing.policy.display_name, "action": "revoke" }),
    )?;
    let now = state.clock.now_rfc3339();
    {
        let database = state
            .database
            .as_ref()
            .ok_or_else(|| internal("no database"))?;
        let mut guard = database.lock();
        // Withdraw the grant and the device grant in one transaction: a half-applied revocation would leave the device signed in.
        let transaction = guard
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|error| internal(&error.to_string()))?;
        crate::guest::set_grant_state(&transaction, &device_id, GrantState::Revoked, &now)
            .map_err(|error| internal(&error.to_string()))?;
        // Retire the device grant too, so the friend's app also loses its signed access.
        crate::store::revoke_device(&transaction, &device_id)
            .map_err(|error| internal(&error.to_string()))?;
        transaction
            .commit()
            .map_err(|error| internal(&error.to_string()))?;
    }
    // Stop what the guest already has running; a stream admitted a moment ago must not outlive the withdrawal.
    let cancelled = crate::request_history::cancel_running_attempts_for(&state, &device_id);
    emit(&state, "shared_access.revoked", &device_id, &now);
    if cancelled > 0 {
        tracing::info!(cancelled, %device_id, "in-flight guest requests cancelled on revocation");
    }
    Ok((
        StatusCode::OK,
        Json(json!({ "device_id": device_id.to_string(), "state": "revoked", "revoked_at": now })),
    ))
}

fn emit(state: &AppState, event: &str, device_id: &uuid::Uuid, at: &str) {
    state.events.emit_scoped(
        None,
        &state.identity.node_id().to_string(),
        None,
        event,
        "notice",
        json!({ "device_id": device_id.to_string(), "at": at }),
        crate::events::Visibility::min_role(Role::Owner),
    );
}
