use super::*;

pub(super) fn coordination_error(
    error: crate::cluster_coordination::CoordinationError,
) -> (StatusCode, Json<Value>) {
    use crate::cluster_coordination::CoordinationError;
    match error {
        CoordinationError::InvalidProposal(_) | CoordinationError::InvalidGrant(_) => {
            cluster_envelope(
                "CLUSTER_EVIDENCE_INVALID",
                &error.to_string(),
                StatusCode::UNPROCESSABLE_ENTITY,
            )
        }
        CoordinationError::OwnerGrantMissing => cluster_envelope(
            "CLUSTER_OWNER_GRANT_MISSING",
            &error.to_string(),
            StatusCode::FORBIDDEN,
        ),
        CoordinationError::Conflict(_) => cluster_envelope(
            "CLUSTER_TRANSACTION_CONFLICT",
            &error.to_string(),
            StatusCode::CONFLICT,
        ),
        CoordinationError::Link(_) | CoordinationError::Runtime(_) => cluster_envelope(
            "CLUSTER_BACKEND_UNAVAILABLE",
            &error.to_string(),
            StatusCode::SERVICE_UNAVAILABLE,
        ),
        CoordinationError::Storage(_) => internal_envelope(&error.to_string()),
    }
}

pub(super) fn require_cluster_owner_presence(
    state: &AppState,
    principal: &Principal,
    authenticated_request: &AuthenticatedRequest,
    headers: &HeaderMap,
) -> Result<(), (StatusCode, Json<Value>)> {
    if principal.role != "owner" {
        return Err(cluster_envelope(
            "ROLE_FORBIDDEN",
            "cluster authorisation is owner-only",
            StatusCode::FORBIDDEN,
        ));
    }
    let key = presence_key(state, principal)?;
    crate::user_presence::verify(
        headers.get(crate::user_presence::HEADER_USER_PRESENCE),
        key.as_deref(),
        authenticated_request,
        state.clock.now(),
    )
    .map_err(|error| {
        cluster_envelope(
            error.code(),
            "fresh user presence is required to change a cluster",
            StatusCode::FORBIDDEN,
        )
    })
}

pub(super) fn append_transaction_acceptance(
    state: &AppState,
    principal: &Principal,
    idempotency: &IdempotencyRequest,
    route: &str,
    action: &str,
    transaction_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
) -> Result<(), (StatusCode, Json<Value>)> {
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("no database"))?;
    let details = json!({
        "cluster_id": cluster_id,
        "transaction_id": transaction_id,
        "idempotency_key": idempotency.key,
        "request_hash": idempotency.body_hash,
    });
    crate::audit::append_committed(
        database,
        state.clock.as_ref(),
        &crate::audit::AuditDraft {
            actor_device_id: Some(principal.device_id),
            actor_role: Some(&principal.role),
            source_route: route,
            action,
            resource: Some(CLUSTER_RESOURCE),
            result: "accepted",
            operation_id: None,
            request_id: idempotency.request_id,
            details: &details,
        },
    )
    .map(|_| ())
    .map_err(crate::audit::unavailable_envelope)
}

pub(super) fn lookup_transaction_replay(
    state: &AppState,
    idempotency: &IdempotencyRequest,
) -> Result<Option<crate::idempotency::IdempotencyOutcome>, (StatusCode, Json<Value>)> {
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("no database"))?;
    state
        .idempotency
        .lookup(&mut database.lock(), idempotency)
        .map_err(|error| error.envelope())
}

pub(super) fn store_transaction_response<T: serde::Serialize>(
    state: &AppState,
    idempotency: &IdempotencyRequest,
    response: &T,
) -> Result<crate::idempotency::IdempotencyOutcome, (StatusCode, Json<Value>)> {
    let _admission = state.idempotency.admission_guard();
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("no database"))?;
    let body =
        serde_json::to_value(response).map_err(|error| internal_envelope(&error.to_string()))?;
    state
        .idempotency
        .execute(&mut database.lock(), idempotency, |_| {
            Ok(StoredResponse {
                status: StatusCode::OK,
                body,
                operation_id: None,
            })
        })
        .map_err(|error| error.envelope())
}
