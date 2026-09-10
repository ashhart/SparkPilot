use super::*;

pub(super) fn apply(
    conn: &Connection,
    state: &AppState,
    actor: Uuid,
    preview_id: Uuid,
) -> Result<Value, PoolError> {
    let row: Option<(String, u64, i64, bool)> = conn.query_row("SELECT policy_json,expected_revision,expires_at,consumed FROM inference_pool_previews WHERE preview_id=?1 AND actor_device_id=?2", params![preview_id.to_string(),actor.to_string()], |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
    let Some((raw, expected, expires, consumed)) = row else {
        return refuse("POOL_PREVIEW_INVALID");
    };
    if consumed || expires <= state.clock.now().unix_timestamp() {
        return refuse("POOL_PREVIEW_EXPIRED");
    }
    let policy: InferencePoolPolicy = serde_json::from_str(&raw)?;
    if policy_revision(conn, policy.pool_id)? != expected {
        return refuse("POOL_POLICY_CHANGED");
    }
    for id in &policy.caller_device_ids {
        eligible_device(conn, *id)?;
    }
    for id in &policy.router_device_ids {
        eligible_router(conn, *id)?;
    }
    let count: u32 = conn.query_row("SELECT count(*) FROM inference_pool_policies", [], |r| {
        r.get(0)
    })?;
    if expected == 0 && count >= MAX_POOLS as u32 {
        return refuse("POOL_LIMIT");
    }
    conn.execute("INSERT INTO inference_pool_policies VALUES(?1,?2,?3,?4,?5) ON CONFLICT(pool_id) DO UPDATE SET revision=excluded.revision,policy_json=excluded.policy_json,owner_device_id=excluded.owner_device_id,updated_at=excluded.updated_at", params![policy.pool_id.to_string(),policy.revision,raw,actor.to_string(),state.clock.now().unix_timestamp()])?;
    conn.execute(
        "UPDATE inference_pool_previews SET consumed=1 WHERE preview_id=?1",
        [preview_id.to_string()],
    )?;
    conn.execute(
        "UPDATE inference_router_grants SET revoked=1 WHERE pool_id=?1",
        [policy.pool_id.to_string()],
    )?;
    conn.execute("UPDATE inference_reservations SET state='cancelled',reason='not_dispatched' WHERE pool_id=?1 AND state='reserved'",[policy.pool_id.to_string()])?;
    Ok(serde_json::to_value(policy)?)
}

pub(super) fn create_grant(
    conn: &Connection,
    state: &AppState,
    actor: Uuid,
    scope: CreateRouterGrantRequest,
) -> Result<Value, PoolError> {
    let policy = load_policy(conn, scope.pool_id)?;
    if policy.paused
        || scope.policy_revision != policy.revision
        || !policy.router_device_ids.contains(&scope.router_device_id)
        || !policy.caller_device_ids.contains(&scope.caller_device_id)
        || scope.actions.is_empty()
        || scope.actions.len() > 4
        || scope.deployment_ids.is_empty()
        || scope.deployment_ids.len() > 16
        || scope
            .deployment_ids
            .iter()
            .any(|id| !policy.deployment_ids.contains(id))
        || scope.expires_in_seconds == 0
        || i64::from(scope.expires_in_seconds) > MAX_GRANT_SECONDS
    {
        return refuse("POOL_GRANT_FORBIDDEN");
    }
    eligible_router(conn, scope.router_device_id)?;
    eligible_device(conn, scope.caller_device_id)?;
    let count: u32 = conn.query_row("SELECT count(*) FROM inference_router_grants", [], |r| {
        r.get(0)
    })?;
    if count >= MAX_GRANTS as u32 {
        return refuse("POOL_GRANT_LIMIT");
    }
    let issued_at = state.clock.now().unix_timestamp();
    let grant = RouterGrant {
        grant_id: Uuid::new_v4(),
        audience_node_id: state.identity.node_id(),
        issued_by_device_id: actor,
        issued_at,
        expires_at: issued_at + i64::from(scope.expires_in_seconds),
        scope,
    };
    conn.execute(
        "INSERT INTO inference_router_grants VALUES(?1,?2,?3,0,?4)",
        params![
            grant.grant_id.to_string(),
            grant.scope.pool_id.to_string(),
            serde_json::to_string(&grant)?,
            grant.expires_at
        ],
    )?;
    Ok(serde_json::to_value(grant)?)
}

pub(super) fn revoke(conn: &Connection, grant_id: Uuid) -> Result<Value, PoolError> {
    if conn.execute(
        "UPDATE inference_router_grants SET revoked=1 WHERE grant_id=?1",
        [grant_id.to_string()],
    )? == 0
    {
        return refuse("POOL_NOT_FOUND");
    }
    conn.execute("UPDATE inference_reservations SET state='cancelled',reason='not_dispatched' WHERE grant_id=?1 AND state='reserved'",[grant_id.to_string()])?;
    Ok(json!({"grant_id":grant_id,"revoked":true,"accepted_work":"drain"}))
}

/// Called only by the node worker, never from router-supplied completion.
pub(super) fn finish(
    state: &AppState,
    id: Uuid,
    confirmed: bool,
    success: bool,
) -> Result<(), PoolError> {
    let conn = database(state)?.lock();
    conn.execute("UPDATE inference_reservations SET state=CASE WHEN ?1=0 THEN 'outcome_unknown' WHEN state='cancel_requested' THEN 'cancelled' WHEN ?2 THEN 'succeeded' ELSE 'failed' END,reason=CASE WHEN ?1=0 THEN 'termination_unconfirmed' ELSE 'node_confirmed' END,capacity_released=CASE WHEN ?1 THEN 1 ELSE capacity_released END,updated_at=?3 WHERE reservation_id=?4 AND state IN ('accepted','cancel_requested','outcome_unknown')",params![confirmed,success,state.clock.now().unix_timestamp(),id.to_string()])?;
    Ok(())
}
