use super::*;

/// Allow operation access only to its actor or elevated roles; conceal other operations as not found.
pub(super) fn is_elevated(principal: &Principal) -> bool {
    matches!(
        crate::capability::Role::parse(&principal.role),
        crate::capability::Role::Owner | crate::capability::Role::Administrator
    )
}

pub(super) fn may_view_operation(
    principal: &Principal,
    operation: &crate::store::OperationRow,
) -> bool {
    is_elevated(principal) || operation.actor_device_id == principal.device_id
}

/// Encode created_at and ID as an opaque URL-safe hexadecimal pagination cursor.
pub(super) fn encode_operation_cursor(created_at: &str, id: &str) -> String {
    hex::encode(format!("{created_at}\u{1f}{id}"))
}

pub(super) fn decode_operation_cursor(token: &str) -> Option<(String, String)> {
    let text = String::from_utf8(hex::decode(token).ok()?).ok()?;
    let (created_at, id) = text.split_once('\u{1f}')?;
    Some((created_at.to_owned(), id.to_owned()))
}

/// Operation-list pagination parameters.
#[derive(serde::Deserialize)]
pub struct OperationListQuery {
    pub limit: Option<u32>,
    pub cursor: Option<String>,
}

pub(super) fn operation_not_found() -> (StatusCode, Json<Value>) {
    (
        StatusCode::NOT_FOUND,
        Json(json!({
            "error": {
                "code": "OPERATION_NOT_FOUND",
                "message": "operation not found",
                "request_id": crate::route::current_request_id(),
            }
        })),
    )
}

/// List visible durable operations.
pub async fn list_operations(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Query(query): Query<OperationListQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let Some(db) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    let limit = query.limit.unwrap_or(50).clamp(1, 200) as usize;
    let after = match query.cursor.as_deref() {
        Some(token) => Some(decode_operation_cursor(token).ok_or_else(|| {
            (
                StatusCode::BAD_REQUEST,
                Json(json!({
                    "error": {
                        "code": "INVALID_REQUEST",
                        "message": "invalid pagination cursor",
                        "request_id": crate::route::current_request_id(),
                    }
                })),
            )
        })?),
        None => None,
    };
    // Filter ordinary devices to their own operations; owners and administrators may inspect all operations.
    let viewer = (!is_elevated(&principal)).then_some(principal.device_id);
    let conn = db.lock();
    let (items, has_more) = state
        .jobs
        .list_page(
            &conn,
            viewer,
            after.as_ref().map(|(a, b)| (a.as_str(), b.as_str())),
            limit,
        )
        .map_err(|error| internal_envelope(&error.to_string()))?;
    let next_cursor = if has_more {
        items
            .last()
            .map(|row| encode_operation_cursor(&row.created_at, &row.id.to_string()))
    } else {
        None
    };
    Ok(Json(json!({ "items": items, "next_cursor": next_cursor })))
}

/// Read one visible durable operation.
pub async fn get_operation(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    RoutePath(id): RoutePath<uuid::Uuid>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let Some(db) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    let conn = db.lock();
    let operation = state
        .jobs
        .get(&conn, id)
        .map_err(|error| internal_envelope(&error.to_string()))?;
    match operation {
        Some(operation) if may_view_operation(&principal, &operation) => Ok(Json(
            serde_json::to_value(operation)
                .map_err(|error| internal_envelope(&error.to_string()))?,
        )),
        _ => Err(operation_not_found()),
    }
}

/// Request cooperative operation cancellation.
pub async fn cancel_operation(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    RoutePath(id): RoutePath<uuid::Uuid>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let Some(db) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    let outcome = {
        let mut conn = db.lock();
        // Check actor or elevated authority before idempotency writes and conceal unauthorized operation IDs as not found.
        match state.jobs.get(&conn, id) {
            Ok(Some(operation)) if may_view_operation(&principal, &operation) => {}
            Ok(_) => {
                crate::audit::append(
                    &conn,
                    state.clock.as_ref(),
                    &crate::audit::AuditDraft {
                        actor_device_id: Some(principal.device_id),
                        actor_role: Some(&principal.role),
                        source_route: "/api/v1/operations/{id}/cancel",
                        action: "operation.cancel",
                        resource: Some(&id.to_string()),
                        result: "refused",
                        operation_id: None,
                        request_id: None,
                        details: &json!({"reason": "not_visible"}),
                    },
                )
                .map_err(crate::audit::unavailable_envelope)?;
                return Err(operation_not_found());
            }
            Err(error) => return Err(internal_envelope(&error.to_string())),
        }
        state
            .idempotency
            .execute(&mut conn, &idempotency, |transaction| {
                let changed = state.jobs.persist_cancellation_request(transaction, id)?;
                if !changed {
                    return Ok(StoredResponse {
                        status: StatusCode::CONFLICT,
                        body: json!({
                            "error": {
                                "code": "OPERATION_NOT_CANCELLABLE",
                                "message": "operation is already terminal",
                                "request_id": crate::route::current_request_id(),
                            }
                        }),
                        operation_id: Some(id),
                    });
                }
                let row = state
                    .jobs
                    .get(transaction, id)?
                    .ok_or(crate::store::StoreError::NotFound("operation"))?;
                Ok(StoredResponse {
                    status: StatusCode::ACCEPTED,
                    body: serde_json::to_value(row)
                        .map_err(|error| crate::store::StoreError::Sqlite(error.to_string()))?,
                    operation_id: Some(id),
                })
            })
            .map_err(|error| error.envelope())?
    };
    if outcome.created && outcome.response.status == StatusCode::ACCEPTED {
        state.jobs.signal_cancellation(id);
    }
    if outcome.response.status.is_success() {
        Ok(json_response(&outcome))
    } else {
        Err(json_response(&outcome))
    }
}
