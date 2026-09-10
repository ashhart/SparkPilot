use super::*;

pub(super) fn role_can_manage(principal: &Principal) -> bool {
    matches!(principal.role.as_str(), "owner" | "administrator")
}

pub(super) fn require_manage_role(
    state: &AppState,
    principal: &Principal,
    idempotency: &IdempotencyRequest,
    route: &'static str,
    kind: &'static str,
) -> Result<(), (StatusCode, Json<Value>)> {
    if role_can_manage(principal) {
        return Ok(());
    }
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("settings database is unavailable"))?;
    crate::audit::append_refusal(
        database,
        state.clock.as_ref(),
        principal.device_id,
        &principal.role,
        route,
        kind,
        Some(SETTINGS_RESOURCE),
        idempotency.request_id,
        "ROLE_FORBIDDEN",
    )
    .map_err(crate::audit::unavailable_envelope)?;
    Err(error_envelope(
        StatusCode::FORBIDDEN,
        "ROLE_FORBIDDEN",
        "this setting requires an owner or administrator",
    ))
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn enqueue_operation<F>(
    state: AppState,
    principal: Principal,
    authenticated_request: AuthenticatedRequest,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    route: &'static str,
    kind: &'static str,
    input: Value,
    confirmation_of: Option<Uuid>,
    worker: F,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)>
where
    F: FnOnce(Uuid, crate::jobs::OperationLease) + Send + 'static,
{
    require_manage_role(&state, &principal, &idempotency, route, kind)?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("settings database is unavailable"))?;

    let _admission = state.idempotency.admission_guard();
    let replay = {
        let mut connection = database.lock();
        state
            .idempotency
            .lookup(&mut connection, &idempotency)
            .map_err(|error| error.envelope())?
    };
    if let Some(outcome) = replay {
        return Ok(json_response(&outcome));
    }

    let presence_key = {
        let connection = database.lock();
        crate::store::load_presence_key_by_device_id(&connection, &principal.device_id)
            .map_err(|error| internal_envelope(&error.to_string()))?
    };
    if let Err(error) = crate::user_presence::verify(
        headers.get(crate::user_presence::HEADER_USER_PRESENCE),
        presence_key.as_deref(),
        &authenticated_request,
        state.clock.now(),
    ) {
        crate::audit::append_refusal(
            database,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            route,
            kind,
            Some(SETTINGS_RESOURCE),
            idempotency.request_id,
            error.code(),
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err(error_envelope(
            StatusCode::FORBIDDEN,
            error.code(),
            "fresh user presence is required to change this setting",
        ));
    }

    if let Some(configuration_id) = confirmation_of {
        let original = {
            let connection = database.lock();
            crate::store::operation_row(&connection, configuration_id)
                .map_err(|error| internal_envelope(&error.to_string()))?
        };
        let is_initiating_device = original.as_ref().is_some_and(|operation| {
            operation.actor_device_id == principal.device_id
                && matches!(
                    operation.kind.as_str(),
                    "network.wifi.connect"
                        | "network.direct_ethernet"
                        | "network.travel_access_point"
                        | "network.lan.ipv4"
                )
        });
        if !is_initiating_device {
            crate::audit::append_refusal(
                database,
                state.clock.as_ref(),
                principal.device_id,
                &principal.role,
                route,
                kind,
                Some(SETTINGS_RESOURCE),
                idempotency.request_id,
                "NETWORK_CONFIRMATION_FORBIDDEN",
            )
            .map_err(crate::audit::unavailable_envelope)?;
            return Err(error_envelope(
                StatusCode::FORBIDDEN,
                "NETWORK_CONFIRMATION_FORBIDDEN",
                "only the device that started this network change can resolve it",
            ));
        }
    }

    let outcome = {
        let mut connection = database.lock();
        state
            .idempotency
            .create_noncancellable_operation_audited(
                &mut connection,
                &idempotency,
                &state.jobs,
                kind,
                None,
                &input.to_string(),
                &principal.role,
                route,
                Some(SETTINGS_RESOURCE),
                &input,
            )
            .map_err(|error| error.envelope())?
    };
    if !outcome.created {
        return Ok(json_response(&outcome));
    }
    let operation_id = outcome.response.operation_id.expect("new operation id");
    state
        .jobs
        .spawn_leased(database.clone(), operation_id, move |lease| {
            worker(operation_id, lease)
        })
        .map_err(|error| internal_envelope(&error.to_string()))?;
    Ok(json_response(&outcome))
}

pub(crate) fn finish_privileged(
    lease: crate::jobs::OperationLease,
    result: Result<spark_privd::protocol::PrivilegedResponse, crate::privd::PrivilegedClientError>,
    success: Value,
    fallback_code: &'static str,
) {
    match result {
        Ok(response) if response.accepted => {
            if let Err(error) = lease.succeed(&success) {
                tracing::error!(%error, "could not persist appliance setting success");
            }
        }
        Ok(response) => {
            if let Err(error) = lease.fail(&response.code) {
                tracing::error!(%error, "could not persist appliance setting refusal");
            }
        }
        Err(error) => {
            tracing::error!(%error, "privileged appliance setting failed");
            if let Err(store_error) = lease.fail(fallback_code) {
                tracing::error!(%store_error, "could not persist appliance setting failure");
            }
        }
    }
}
