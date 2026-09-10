use super::*;

/// List every guest with its policy, its state and what it has used, for the owner alone.
pub async fn list_shared_access(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult<Json<Value>> {
    state
        .require(&principal, Capability::SharedAccessRead)
        .resource("shared-access")
        .check()?;
    let grants = {
        let database = state
            .database
            .as_ref()
            .ok_or_else(|| internal("no database"))?;
        let guard = database.lock();
        crate::guest::list_grants(&guard).map_err(|error| internal(&error.to_string()))?
    };
    let now = state.clock.now();
    let mut guests = Vec::with_capacity(grants.len());
    for grant in &grants {
        guests.push(guest_json(&state, grant, now)?);
    }
    Ok(Json(json!({ "guests": guests })))
}

fn guest_json(state: &AppState, grant: &GuestGrant, now: time::OffsetDateTime) -> ApiResult<Value> {
    let zone = TimeZone::load(&grant.policy.time_zone).ok();
    let week = week_of(zone.as_ref(), now);
    let today = week.last().cloned().unwrap_or_default();
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal("no database"))?;
    let guard = database.lock();
    let (today_usage, week_usage, refusals, last_seen) = match grant.device_id {
        Some(device_id) => (
            crate::guest::usage_over(&guard, &device_id, std::slice::from_ref(&today))
                .map_err(|error| internal(&error.to_string()))?,
            crate::guest::usage_over(&guard, &device_id, &week)
                .map_err(|error| internal(&error.to_string()))?,
            crate::guest::refusals_by_reason(&guard, &device_id, &week)
                .map_err(|error| internal(&error.to_string()))?,
            crate::store::device_row(&guard, &device_id)
                .ok()
                .flatten()
                .and_then(|row| row.last_seen_at),
        ),
        None => (
            UsageTotals::default(),
            UsageTotals::default(),
            Default::default(),
            None,
        ),
    };
    Ok(json!({
        "invitation_id": grant.invitation_id.to_string(),
        "device_id": grant.device_id.map(|id| id.to_string()),
        "display_name": grant.policy.display_name,
        "state": grant.policy.state.name(),
        "allowed_models": grant.policy.allowed_models,
        "allowed_hours": hours_json(&grant.policy.allowed_hours),
        "time_zone": grant.policy.time_zone,
        "max_concurrent_requests": grant.policy.max_concurrent_requests,
        "daily_token_budget": grant.policy.daily_token_budget,
        "expires_at": grant.policy.expires_at,
        "joined_at": grant.joined_at,
        "confirmed_at": grant.confirmed_at,
        "revoked_at": grant.revoked_at,
        "last_seen_at": last_seen,
        "today": usage_json(&today_usage),
        "this_week": usage_json(&week_usage),
        "refusals_this_week": refusals,
    }))
}

/// A guest's own record: its limits, today's use against the budget, and when the budget resets.
pub async fn own_shared_access(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult<Json<Value>> {
    state
        .require(&principal, Capability::SharedAccessReadOwn)
        .resource("shared-access/self")
        .check()?;
    if Role::parse(&principal.role) != Role::Guest {
        return Err(envelope(
            "OPERATION_NOT_FOUND",
            "this device is not using shared access",
            StatusCode::NOT_FOUND,
        ));
    }
    let grant = grant_of(&state, &principal.device_id)?;
    let zone = TimeZone::load(&grant.policy.time_zone).ok();
    let now = state.clock.now();
    let today = match &zone {
        Some(zone) => zone
            .local_at(now.unix_timestamp())
            .map(|local| local.date())
            .unwrap_or_else(|_| utc_date(now.unix_timestamp())),
        None => utc_date(now.unix_timestamp()),
    };
    let usage = {
        let database = state
            .database
            .as_ref()
            .ok_or_else(|| internal("no database"))?;
        let guard = database.lock();
        crate::guest::usage_over(&guard, &principal.device_id, std::slice::from_ref(&today))
            .map_err(|error| internal(&error.to_string()))?
    };
    let resets_at = zone
        .as_ref()
        .and_then(|zone| zone.next_local_midnight(now.unix_timestamp()).ok());
    Ok(Json(json!({
        "display_name": grant.policy.display_name,
        "state": grant.policy.state.name(),
        "allowed_models": grant.policy.allowed_models,
        "allowed_hours": hours_json(&grant.policy.allowed_hours),
        "time_zone": grant.policy.time_zone,
        "max_concurrent_requests": grant.policy.max_concurrent_requests,
        "daily_token_budget": grant.policy.daily_token_budget,
        "expires_at": grant.policy.expires_at,
        "today": usage_json(&usage),
        "budget_resets_at": resets_at,
    })))
}
