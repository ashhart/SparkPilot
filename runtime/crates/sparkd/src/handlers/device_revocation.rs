use super::*;

/// Revoke a paired device grant.
pub async fn revoke_device(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Path(device_id): Path<uuid::Uuid>,
) -> HandlerResult<(StatusCode, Json<Value>)> {
    let resource = format!("device/{device_id}");
    if !principal.is_admin() {
        crate::audit::append_refusal(
            state.database.as_ref().ok_or_else(internal_error)?,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            "/api/v1/devices/{device_id}",
            "device.revoke",
            Some(&resource),
            idempotency.request_id,
            "ROLE_FORBIDDEN",
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err((
            StatusCode::FORBIDDEN,
            error_envelope("ROLE_FORBIDDEN", &uuid::Uuid::new_v4().to_string()),
        ));
    }
    if device_id == principal.device_id {
        // Refuse administrator self-revocation through this route; ownership recovery uses a separate flow.
        crate::audit::append_refusal(
            state.database.as_ref().ok_or_else(internal_error)?,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            "/api/v1/devices/{device_id}",
            "device.revoke",
            Some(&resource),
            idempotency.request_id,
            "SELF_REVOCATION_FORBIDDEN",
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err(pairing_error_response(PairingError::RoleMismatch(
            "owner recovery",
        )));
    }
    {
        let mut guard = state.database.as_ref().ok_or(internal_error())?.lock();
        if let Some(outcome) = state
            .idempotency
            .lookup(&mut guard, &idempotency)
            .map_err(|error| error.envelope())?
        {
            return if outcome.response.status.is_success() {
                Ok(json_response(&outcome))
            } else {
                Err(json_response(&outcome))
            };
        }
    }
    {
        let guard = state.database.as_ref().ok_or(internal_error())?.lock();
        match revoke_authorization(&guard, &principal.role, &device_id) {
            Ok(RevokeAuthorization::Allowed) => {}
            Ok(RevokeAuthorization::Forbidden) => {
                drop(guard);
                crate::audit::append_refusal(
                    state.database.as_ref().ok_or_else(internal_error)?,
                    state.clock.as_ref(),
                    principal.device_id,
                    &principal.role,
                    "/api/v1/devices/{device_id}",
                    "device.revoke",
                    Some(&resource),
                    idempotency.request_id,
                    "ROLE_FORBIDDEN",
                )
                .map_err(crate::audit::unavailable_envelope)?;
                return Err((
                    StatusCode::FORBIDDEN,
                    error_envelope("ROLE_FORBIDDEN", &uuid::Uuid::new_v4().to_string()),
                ));
            }
            Err(error) => {
                let response = pairing_error_response(PairingError::Store(error));
                let reason = crate::audit::response_code(&response, "DEVICE_REVOKE_FAILED");
                drop(guard);
                crate::audit::append_refusal(
                    state.database.as_ref().ok_or_else(internal_error)?,
                    state.clock.as_ref(),
                    principal.device_id,
                    &principal.role,
                    "/api/v1/devices/{device_id}",
                    "device.revoke",
                    Some(&resource),
                    idempotency.request_id,
                    &reason,
                )
                .map_err(crate::audit::unavailable_envelope)?;
                return Err(response);
            }
        }
    }
    let presence_key = {
        let guard = state.database.as_ref().ok_or(internal_error())?.lock();
        crate::store::load_presence_key_by_device_id(&guard, &principal.device_id)
            .map_err(|error| pairing_error_response(PairingError::Store(error)))?
    };
    if let Err(error) = crate::user_presence::verify(
        headers.get(crate::user_presence::HEADER_USER_PRESENCE),
        presence_key.as_deref(),
        &authenticated_request,
        state.clock.now(),
    ) {
        crate::audit::append_refusal(
            state.database.as_ref().ok_or_else(internal_error)?,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            "/api/v1/devices/{device_id}",
            "device.revoke",
            Some(&resource),
            idempotency.request_id,
            error.code(),
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err((
            StatusCode::FORBIDDEN,
            error_envelope(error.code(), &uuid::Uuid::new_v4().to_string()),
        ));
    }
    let mut guard = state.database.as_ref().ok_or(internal_error())?.lock();
    let outcome = state
        .idempotency
        .execute(&mut guard, &idempotency, |transaction| {
            match revoke_authorization(transaction, &principal.role, &device_id) {
                Ok(RevokeAuthorization::Allowed) => {}
                Ok(RevokeAuthorization::Forbidden) => {
                    crate::audit::append(
                        transaction,
                        state.clock.as_ref(),
                        &crate::audit::AuditDraft {
                            actor_device_id: Some(principal.device_id),
                            actor_role: Some(&principal.role),
                            source_route: "/api/v1/devices/{device_id}",
                            action: "device.revoke",
                            resource: Some(&resource),
                            result: "refused",
                            operation_id: None,
                            request_id: idempotency.request_id,
                            details: &json!({ "reason_code": "ROLE_FORBIDDEN" }),
                        },
                    )?;
                    return Ok(StoredResponse {
                        status: StatusCode::FORBIDDEN,
                        body: error_envelope("ROLE_FORBIDDEN", &uuid::Uuid::new_v4().to_string()).0,
                        operation_id: None,
                    });
                }
                Err(error) => {
                    let (status, Json(body)) = pairing_error_response(PairingError::Store(error));
                    return Ok(StoredResponse {
                        status,
                        body,
                        operation_id: None,
                    });
                }
            }
            match crate::store::revoke_device(transaction, &device_id) {
                Ok(()) => {
                    crate::audit::append(
                        transaction,
                        state.clock.as_ref(),
                        &crate::audit::AuditDraft {
                            actor_device_id: Some(principal.device_id),
                            actor_role: Some(&principal.role),
                            source_route: "/api/v1/devices/{device_id}",
                            action: "device.revoke",
                            resource: Some(&resource),
                            result: "succeeded",
                            operation_id: None,
                            request_id: idempotency.request_id,
                            details: &json!({}),
                        },
                    )?;
                    // §15.8: the revocation is an event as well as an audit record, in the same transaction.
                    state.events.emit_scoped(
                        Some(transaction),
                        &state.identity.node_id().to_string(),
                        None,
                        "device.revoked",
                        "warning",
                        json!({ "device_id": device_id }),
                        crate::events::Visibility::min_role(crate::capability::Role::Administrator),
                    );
                    Ok(StoredResponse {
                        status: StatusCode::NO_CONTENT,
                        body: Value::Null,
                        operation_id: None,
                    })
                }
                Err(error) => {
                    let (status, Json(body)) = pairing_error_response(PairingError::Store(error));
                    let reason = body
                        .get("error")
                        .and_then(|error| error.get("code"))
                        .and_then(Value::as_str)
                        .unwrap_or("DEVICE_REVOKE_FAILED");
                    crate::audit::append(
                        transaction,
                        state.clock.as_ref(),
                        &crate::audit::AuditDraft {
                            actor_device_id: Some(principal.device_id),
                            actor_role: Some(&principal.role),
                            source_route: "/api/v1/devices/{device_id}",
                            action: "device.revoke",
                            resource: Some(&resource),
                            result: "refused",
                            operation_id: None,
                            request_id: idempotency.request_id,
                            details: &json!({ "reason_code": reason }),
                        },
                    )?;
                    Ok(StoredResponse {
                        status,
                        body,
                        operation_id: None,
                    })
                }
            }
        })
        .map_err(|error| error.envelope())?;
    if outcome.response.status.is_success() {
        Ok(json_response(&outcome))
    } else {
        Err(json_response(&outcome))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RevokeAuthorization {
    Allowed,
    Forbidden,
}

pub(super) fn revoke_authorization(
    conn: &rusqlite::Connection,
    actor_role: &str,
    target_id: &uuid::Uuid,
) -> Result<RevokeAuthorization, crate::store::StoreError> {
    let target_role = crate::store::load_active_device_role(conn, target_id)?
        .ok_or(crate::store::StoreError::NotFound("device"))?;
    let role_allowed = match actor_role {
        "owner" => true,
        "administrator" => matches!(target_role.as_str(), "developer" | "user" | "observer"),
        _ => false,
    };
    if !role_allowed {
        return Ok(RevokeAuthorization::Forbidden);
    }
    if target_role == "owner" && crate::store::active_owner_count(conn)? <= 1 {
        return Ok(RevokeAuthorization::Forbidden);
    }
    Ok(RevokeAuthorization::Allowed)
}
