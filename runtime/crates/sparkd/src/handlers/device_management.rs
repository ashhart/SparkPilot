use super::*;

/// List paired devices for administrators.
pub async fn list_devices(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> HandlerResult<Json<Value>> {
    // Device listing requires administrative authority but consumes no presence and applies no individual target-authority ceiling.
    state
        .require(&principal, crate::capability::Capability::DeviceRead)
        .resource("devices")
        .check()?;
    let guard = state.database.as_ref().ok_or(internal_error())?.lock();
    let devices = crate::store::list_devices(&guard)
        .map_err(|e| pairing_error_response(PairingError::Store(e)))?;
    Ok(Json(json!({ "items": devices })))
}

pub async fn update_device(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Path(device_id): Path<uuid::Uuid>,
    Json(body): Json<Value>,
) -> HandlerResult<(StatusCode, Json<Value>)> {
    let Some(object) = body.as_object() else {
        return Err(unprocessable("PATCH_INVALID", "body must be a JSON object"));
    };
    for key in object.keys() {
        if !matches!(key.as_str(), "display_name" | "role") {
            return Err(unprocessable(
                "PATCH_INVALID",
                &format!(
                    "unsupported field {:?}; only display_name and role may be patched",
                    crate::api_error::abbreviated(key)
                ),
            ));
        }
    }
    let display_name = match object.get("display_name") {
        None => None,
        Some(Value::String(name)) if (1..=120).contains(&name.chars().count()) => {
            Some(name.clone())
        }
        Some(_) => {
            return Err(unprocessable(
                "PATCH_INVALID",
                "display_name must be a string of 1..=120 characters",
            ));
        }
    };
    let requested_role = match object.get("role") {
        None => None,
        Some(Value::String(role)) if pairing::ROLES.contains(&role.as_str()) => Some(role.clone()),
        Some(_) => {
            return Err(unprocessable(
                "PATCH_INVALID",
                "role must be one of observer, user, developer, administrator, owner",
            ));
        }
    };
    if display_name.is_none() && requested_role.is_none() {
        return Err(unprocessable(
            "PATCH_INVALID",
            "patch must change display_name or role",
        ));
    }

    let stored_role = {
        let guard = state.database.as_ref().ok_or(internal_error())?.lock();
        crate::store::device_role(&guard, &device_id)
            .map_err(|error| pairing_error_response(PairingError::Store(error)))?
    };
    let Some(stored_role) = stored_role else {
        return Err(pairing_error_response(PairingError::Store(
            crate::store::StoreError::NotFound("device"),
        )));
    };
    let role_changes = requested_role
        .as_deref()
        .is_some_and(|role| role != stored_role);
    if role_changes && device_id == principal.device_id {
        return Err(pairing_error_response(PairingError::RoleMismatch(
            "a device cannot change its own role",
        )));
    }

    let new_role = requested_role.as_deref().unwrap_or(&stored_role);
    // Pairing admits one owner per Spark, so promotion must not create a second one.
    if role_changes && new_role == "owner" {
        let owners = {
            let guard = state.database.as_ref().ok_or(internal_error())?.lock();
            crate::store::active_owner_count(&guard)
                .map_err(|error| pairing_error_response(PairingError::Store(error)))?
        };
        if owners > 0 {
            crate::audit::append_refusal(
                state.database.as_ref().ok_or_else(internal_error)?,
                state.clock.as_ref(),
                principal.device_id,
                &principal.role,
                "/api/v1/devices/{device_id}",
                "device.update",
                Some(&format!("device/{device_id}")),
                idempotency.request_id,
                "OWNER_ALREADY_EXISTS",
            )
            .map_err(crate::audit::unavailable_envelope)?;
            return Err(pairing_error_response(PairingError::OwnerAlreadyExists));
        }
    }
    // Verify the enrolled presence key once for privileged role changes and feed the result into both capability checks.
    let privileged = |role: &str| {
        matches!(
            crate::capability::Role::parse(role),
            crate::capability::Role::Administrator | crate::capability::Role::Owner
        )
    };
    let presence = if privileged(&stored_role) || (role_changes && privileged(new_role)) {
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
                "device.update",
                Some(&format!("device/{device_id}")),
                idempotency.request_id,
                error.code(),
            )
            .map_err(crate::audit::unavailable_envelope)?;
            return Err((
                StatusCode::FORBIDDEN,
                error_envelope(error.code(), &crate::route::current_request_id()),
            ));
        }
        crate::capability::Presence::Fresh
    } else {
        crate::capability::Presence::Absent
    };
    state
        .require(&principal, crate::capability::Capability::DevicePair)
        .on_device(crate::capability::Role::parse(&stored_role))
        .resource(format!("device/{device_id}"))
        .details(json!({ "target_role": stored_role, "rename": display_name.is_some() }))
        .check_with_verified_presence(presence)?;
    if role_changes {
        state
            .require(&principal, crate::capability::Capability::DevicePair)
            .on_device(crate::capability::Role::parse(new_role))
            .resource(format!("device/{device_id}"))
            .details(json!({ "from_role": stored_role, "to_role": new_role }))
            .check_with_verified_presence(presence)?;
    }

    let mut guard = state.database.as_ref().ok_or(internal_error())?.lock();
    let outcome = state
        .idempotency
        .execute(&mut guard, &idempotency, |transaction| {
            // Re-check inside the transaction so two concurrent promotions cannot both pass the pre-check.
            if role_changes
                && new_role == "owner"
                && crate::store::active_owner_count(transaction)? > 0
            {
                return Ok(StoredResponse {
                    status: StatusCode::CONFLICT,
                    body: error_envelope("ROLE_FORBIDDEN", &crate::route::current_request_id()).0,
                    operation_id: None,
                });
            }
            crate::store::update_device(
                transaction,
                &device_id,
                display_name.as_deref(),
                requested_role.as_deref(),
            )?;
            let row = crate::store::device_row(transaction, &device_id)?
                .ok_or(crate::store::StoreError::NotFound("device"))?;
            Ok(StoredResponse {
                status: StatusCode::OK,
                body: serde_json::to_value(&row).unwrap_or(Value::Null),
                operation_id: None,
            })
        })
        .map_err(|error| error.envelope())?;
    Ok(json_response(&outcome))
}
