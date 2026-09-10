//! Authorize owner-only power actions with authentication, replay protection, fresh presence and audit before typed privileged dispatch.

use std::time::Duration;

use axum::extract::{Extension, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Json;
use serde_json::{Value, json};
use spark_privd::protocol::PrivilegedOperation;
use uuid::Uuid;

use crate::auth::{AuthenticatedRequest, Principal};
use crate::idempotency::{IdempotencyRequest, json_response};
use crate::state::AppState;

const POWER_RESOURCE: &str = "host-power";
const REBOOT_ROUTE: &str = "/api/v1/power/reboot";
const SHUTDOWN_ROUTE: &str = "/api/v1/power/shutdown";

#[derive(Clone, Copy)]
enum PowerAction {
    Reboot,
    Shutdown,
}

impl PowerAction {
    fn route(self) -> &'static str {
        match self {
            Self::Reboot => REBOOT_ROUTE,
            Self::Shutdown => SHUTDOWN_ROUTE,
        }
    }

    fn operation_kind(self) -> &'static str {
        match self {
            Self::Reboot => "power.reboot",
            Self::Shutdown => "power.shutdown",
        }
    }

    fn privileged_operation(self, request_id: Uuid) -> PrivilegedOperation {
        match self {
            Self::Reboot => PrivilegedOperation::Reboot { request_id },
            Self::Shutdown => PrivilegedOperation::Shutdown { request_id },
        }
    }
}

fn internal_envelope(detail: &str) -> (StatusCode, Json<Value>) {
    error_envelope(StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL", detail)
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

fn append_refusal(
    state: &AppState,
    principal: &Principal,
    idempotency: &IdempotencyRequest,
    action: PowerAction,
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
        action.route(),
        action.operation_kind(),
        Some(POWER_RESOURCE),
        idempotency.request_id,
        reason_code,
    )
    .map(|_| ())
    .map_err(crate::audit::unavailable_envelope)
}

pub async fn reboot(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    power_action(
        state,
        principal,
        authenticated_request,
        idempotency,
        headers,
        PowerAction::Reboot,
    )
}

pub async fn shutdown(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    power_action(
        state,
        principal,
        authenticated_request,
        idempotency,
        headers,
        PowerAction::Shutdown,
    )
}

fn power_action(
    state: AppState,
    principal: Principal,
    authenticated_request: AuthenticatedRequest,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    action: PowerAction,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let Some(database) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    if principal.role != "owner" {
        append_refusal(&state, &principal, &idempotency, action, "ROLE_FORBIDDEN")?;
        return Err(error_envelope(
            StatusCode::FORBIDDEN,
            "ROLE_FORBIDDEN",
            "host power controls are owner-only",
        ));
    }
    let Some(privileged) = state.privileged.clone() else {
        append_refusal(
            &state,
            &principal,
            &idempotency,
            action,
            "POWER_SERVICE_UNAVAILABLE",
        )?;
        return Err(error_envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "POWER_SERVICE_UNAVAILABLE",
            "host power controls are unavailable",
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
        append_refusal(&state, &principal, &idempotency, action, error.code())?;
        return Err(error_envelope(
            StatusCode::FORBIDDEN,
            error.code(),
            "fresh user presence is required for host power controls",
        ));
    }

    let outcome = {
        let mut connection = database.lock();
        state
            .idempotency
            .create_noncancellable_operation_audited(
                &mut connection,
                &idempotency,
                &state.jobs,
                action.operation_kind(),
                None,
                "{}",
                &principal.role,
                action.route(),
                Some(POWER_RESOURCE),
                &json!({}),
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
            // Allow the HTTP response to leave before the requested power action tears down networking.
            std::thread::sleep(Duration::from_secs(1));
            match privileged.call(action.privileged_operation(operation_id)) {
                Ok(response) if response.accepted => {
                    if let Err(error) = lease.succeed(&json!({ "accepted": true })) {
                        tracing::error!(%operation_id, %error, "could not persist power success");
                    }
                }
                Ok(response) => {
                    if let Err(error) = lease.fail(&response.code) {
                        tracing::error!(%operation_id, %error, "could not persist power refusal");
                    }
                }
                Err(error) => {
                    tracing::error!(%operation_id, %error, "privileged power action failed");
                    if let Err(store_error) = lease.fail("POWER_ACTION_FAILED") {
                        tracing::error!(%operation_id, %store_error, "could not persist power failure");
                    }
                }
            }
        })
        .map_err(|error| internal_envelope(&error.to_string()))?;

    Ok(json_response(&outcome))
}
