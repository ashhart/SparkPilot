//! Owner-mediated identity ceremony; a descriptor alone never enrolls a peer.
use crate::{
    auth::{AuthenticatedRequest, Principal},
    idempotency::IdempotencyRequest,
    pool::{self, PoolError},
    pool_router_contracts::*,
    pool_router_identity as identity,
    state::AppState,
};
use axum::{
    Extension, Json,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
};
use rusqlite::TransactionBehavior;
use serde_json::Value;
use uuid::Uuid;
type ApiResult = Result<Json<Value>, (StatusCode, Json<Value>)>;
fn owner(p: &Principal) -> Result<(), (StatusCode, Json<Value>)> {
    if p.role != "owner" {
        Err(PoolError::Refused("POOL_ROLE_FORBIDDEN").envelope())
    } else {
        Ok(())
    }
}
pub async fn read(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult {
    owner(&principal)?;
    let doc = state
        .router_identity
        .load()
        .and_then(|key| key.document(&state))
        .map_err(PoolError::envelope)?;
    Ok(Json(
        serde_json::to_value(doc)
            .map_err(PoolError::from)
            .map_err(PoolError::envelope)?,
    ))
}
pub async fn prepare(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(auth): Extension<AuthenticatedRequest>,
    key: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<PrepareRouterIdentityRequest>,
) -> ApiResult {
    crate::pool_api::mutate(&state, &principal, &auth, &headers, &key, |_conn| {
        let doc = state
            .router_identity
            .prepare(&state, request.expected_key_fingerprint.as_deref())?;
        Ok(serde_json::to_value(doc)?)
    })
}
pub async fn peers(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> ApiResult {
    owner(&principal)?;
    let key = state.router_identity.load().map_err(PoolError::envelope)?;
    let conn = pool::database(&state).map_err(PoolError::envelope)?.lock();
    pool::eligible_owner(&conn, principal.device_id).map_err(PoolError::envelope)?;
    let value = identity::peer_inventory(&conn, key.principal_id).map_err(PoolError::envelope)?;
    Ok(Json(
        serde_json::to_value(value)
            .map_err(PoolError::from)
            .map_err(PoolError::envelope)?,
    ))
}
pub async fn challenge(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    key: IdempotencyRequest,
    Json(request): Json<CreateRouterEnrollmentRequest>,
) -> ApiResult {
    owner(&principal)?;
    state.pools.prepare(&state).map_err(PoolError::envelope)?;
    let mut conn = pool::database(&state).map_err(PoolError::envelope)?.lock();
    let tx = conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(PoolError::from)
        .map_err(PoolError::envelope)?;
    pool::eligible_owner(&tx, principal.device_id).map_err(PoolError::envelope)?;
    if let Some(value) = pool::lookup_mutation(&tx, &key).map_err(PoolError::envelope)? {
        return Ok(Json(value));
    }
    let value = identity::create_challenge(&tx, &state, principal.device_id, request)
        .map_err(PoolError::envelope)?;
    pool::store_mutation(&tx, &key, &value, state.clock.now().unix_timestamp())
        .map_err(PoolError::envelope)?;
    tx.commit()
        .map_err(PoolError::from)
        .map_err(PoolError::envelope)?;
    Ok(Json(value))
}
pub async fn proof(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(auth): Extension<AuthenticatedRequest>,
    key: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<ProveRouterEnrollmentRequest>,
) -> ApiResult {
    owner(&principal)?;
    {
        let conn = pool::database(&state).map_err(PoolError::envelope)?.lock();
        pool::eligible_owner(&conn, principal.device_id).map_err(PoolError::envelope)?;
        if let Some(value) = pool::lookup_mutation(&conn, &key).map_err(PoolError::envelope)? {
            return Ok(Json(value));
        }
    }
    identity::validate_proof_request(&state, &request).map_err(PoolError::envelope)?;
    crate::pool_router_transport::probe_enrollment(&request.recipient)
        .await
        .map_err(PoolError::envelope)?;
    crate::pool_api::mutate(&state, &principal, &auth, &headers, &key, |conn| {
        identity::prove(conn, &state, principal.device_id, request)
    })
}
pub async fn apply(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(auth): Extension<AuthenticatedRequest>,
    key: IdempotencyRequest,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    Json(proof): Json<RouterEnrollmentProof>,
) -> ApiResult {
    crate::pool_api::mutate(&state, &principal, &auth, &headers, &key, |conn| {
        identity::enroll(conn, &state, principal.device_id, id, proof)
    })
}
pub async fn revoke(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(auth): Extension<AuthenticatedRequest>,
    key: IdempotencyRequest,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
) -> ApiResult {
    crate::pool_api::mutate(&state, &principal, &auth, &headers, &key, |conn| {
        identity::revoke(conn, id)
    })
}
