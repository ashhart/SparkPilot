use super::*;

pub(super) async fn resolve_network_change(
    state: AppState,
    principal: Principal,
    authenticated: AuthenticatedRequest,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    configuration_id: Uuid,
    confirm: bool,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let (route, kind) = if confirm {
        (
            "/api/v1/network/changes/{configurationId}/confirm",
            "network.change.confirm",
        )
    } else {
        (
            "/api/v1/network/changes/{configurationId}/rollback",
            "network.change.rollback",
        )
    };
    require_manage_role(&state, &principal, &idempotency, route, kind)?;
    let privileged = state.privileged.clone().ok_or_else(|| {
        error_envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "NETWORK_SERVICE_UNAVAILABLE",
            "network failsafe management is unavailable",
        )
    })?;
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        route,
        kind,
        json!({ "configuration_id": configuration_id }),
        Some(configuration_id),
        move |operation_id, lease| {
            let operation = if confirm {
                PrivilegedOperation::ConfirmNetworkChange {
                    request_id: operation_id,
                    configuration_id,
                }
            } else {
                PrivilegedOperation::RollbackNetworkChange {
                    request_id: operation_id,
                    configuration_id,
                }
            };
            finish_privileged(
                lease,
                privileged.call(operation),
                json!({ "configuration_id": configuration_id, "confirmed": confirm }),
                "NETWORK_FAILSAFE_FAILED",
            );
        },
    )
    .await
}

pub async fn confirm_network_change(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    AxumPath(configuration_id): AxumPath<Uuid>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    resolve_network_change(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        configuration_id,
        true,
    )
    .await
}

pub async fn rollback_network_change(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    AxumPath(configuration_id): AxumPath<Uuid>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    resolve_network_change(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        configuration_id,
        false,
    )
    .await
}
