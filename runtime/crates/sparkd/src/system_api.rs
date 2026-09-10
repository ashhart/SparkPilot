//! Require signed owner authority, fresh presence and replay protection for typed hostname changes without shell input.

use axum::Json;
use axum::extract::{Extension, State};
use axum::http::{HeaderMap, StatusCode};
use serde::Deserialize;
use serde_json::{Value, json};
use spark_privd::protocol::{PrivilegedOperation, valid_system_hostname};

use crate::auth::{AuthenticatedRequest, Principal};
use crate::idempotency::{IdempotencyRequest, json_response};
use crate::state::AppState;

const HOSTNAME_ROUTE: &str = "/api/v1/system/hostname";
const HOSTNAME_RESOURCE: &str = "system-hostname";
const HOSTNAME_OPERATION: &str = "system.hostname";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetHostnameRequest {
    pub hostname: String,
}

fn error_envelope(status: StatusCode, code: &str, message: &str) -> (StatusCode, Json<Value>) {
    (
        status,
        Json(json!({
            "error": {
                "code": code,
                "message": message,
                "request_id": crate::route::current_request_id(),
            }
        })),
    )
}

fn internal_envelope(detail: &str) -> (StatusCode, Json<Value>) {
    error_envelope(StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL", detail)
}

fn append_refusal(
    state: &AppState,
    principal: &Principal,
    idempotency: &IdempotencyRequest,
    reason_code: &str,
) -> Result<(), (StatusCode, Json<Value>)> {
    crate::audit::append_refusal(
        state
            .database
            .as_ref()
            .ok_or_else(|| internal_envelope("no database"))?,
        state.clock.as_ref(),
        principal.device_id,
        &principal.role,
        HOSTNAME_ROUTE,
        HOSTNAME_OPERATION,
        Some(HOSTNAME_RESOURCE),
        idempotency.request_id,
        reason_code,
    )
    .map(|_| ())
    .map_err(crate::audit::unavailable_envelope)
}

pub async fn set_hostname(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<SetHostnameRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let Some(database) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    if principal.role != "owner" {
        append_refusal(&state, &principal, &idempotency, "ROLE_FORBIDDEN")?;
        return Err(error_envelope(
            StatusCode::FORBIDDEN,
            "ROLE_FORBIDDEN",
            "hostname changes are owner-only",
        ));
    }
    if !valid_system_hostname(&request.hostname) {
        append_refusal(&state, &principal, &idempotency, "INVALID_HOSTNAME")?;
        return Err(error_envelope(
            StatusCode::BAD_REQUEST,
            "INVALID_HOSTNAME",
            "hostname must be one lowercase label of up to 63 letters, numbers, or hyphens",
        ));
    }
    let Some(privileged) = state.privileged.clone() else {
        append_refusal(
            &state,
            &principal,
            &idempotency,
            "HOSTNAME_SERVICE_UNAVAILABLE",
        )?;
        return Err(error_envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "HOSTNAME_SERVICE_UNAVAILABLE",
            "hostname changes are unavailable",
        ));
    };

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
        append_refusal(&state, &principal, &idempotency, error.code())?;
        return Err(error_envelope(
            StatusCode::FORBIDDEN,
            error.code(),
            "fresh user presence is required to change the hostname",
        ));
    }

    let hostname = request.hostname;
    let outcome = {
        let mut connection = database.lock();
        state
            .idempotency
            .create_noncancellable_operation_audited(
                &mut connection,
                &idempotency,
                &state.jobs,
                HOSTNAME_OPERATION,
                None,
                &json!({ "hostname": hostname }).to_string(),
                &principal.role,
                HOSTNAME_ROUTE,
                Some(HOSTNAME_RESOURCE),
                &json!({ "hostname": hostname }),
            )
            .map_err(|error| error.envelope())?
    };
    if !outcome.created {
        return Ok(json_response(&outcome));
    }

    let operation_id = outcome.response.operation_id.expect("new operation id");
    let worker_database = database.clone();
    state
        .jobs
        .spawn_leased(worker_database, operation_id, move |lease| {
            match privileged.call(PrivilegedOperation::SetHostname {
                request_id: operation_id,
                hostname: hostname.clone(),
            }) {
                Ok(response) if response.accepted => {
                    if let Err(error) = lease.succeed(&json!({ "hostname": hostname })) {
                        tracing::error!(%operation_id, %error, "could not persist hostname success");
                    }
                }
                Ok(response) => {
                    if let Err(error) = lease.fail(&response.code) {
                        tracing::error!(%operation_id, %error, "could not persist hostname refusal");
                    }
                }
                Err(error) => {
                    tracing::error!(%operation_id, %error, "privileged hostname change failed");
                    if let Err(store_error) = lease.fail("HOSTNAME_CHANGE_FAILED") {
                        tracing::error!(%operation_id, %store_error, "could not persist hostname failure");
                    }
                }
            }
        })
        .map_err(|error| internal_envelope(&error.to_string()))?;

    Ok(json_response(&outcome))
}
