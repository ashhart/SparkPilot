use super::*;

pub async fn update_open_webui(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let recipe = recipe(&state)?;
    let client = privileged(&state)?;
    let database = state.database.clone().ok_or_else(|| {
        envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "OPTIONAL_SERVICES_UNAVAILABLE",
            "optional service state is unavailable",
        )
    })?;
    let configured = database
        .lock()
        .query_row(
            "SELECT enabled FROM optional_services WHERE service_id = ?1",
            [SERVICE_ID],
            |row| row.get::<_, bool>(0),
        )
        .unwrap_or(false);
    if !configured {
        return Err(envelope(
            StatusCode::CONFLICT,
            "OPEN_WEBUI_GATEWAY_STATE_MISSING",
            "Open WebUI must be installed with a healthy scoped gateway before it can be updated",
        ));
    }
    let image_digest = recipe.container.image;
    let revision = recipe.metadata.revision;
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/services/open-webui/update",
        "service.open_webui.update",
        json!({ "service_id": SERVICE_ID, "recipe_revision": revision }),
        None,
        move |operation_id, lease| {
            let result = client.call(PrivilegedOperation::UpdateOpenWebUi {
                request_id: operation_id,
                image_digest: image_digest.clone(),
            });
            match result {
                Ok(response) if response.accepted => {
                    let persisted = database.lock().execute(
                        "UPDATE optional_services
                            SET recipe_revision = ?1,
                                updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                          WHERE service_id = ?2 AND enabled = 1",
                        rusqlite::params![revision, SERVICE_ID],
                    );
                    match persisted {
                        Ok(1) => {
                            lease.settle_succeeded(
                                &json!({ "service_id": SERVICE_ID, "recipe_revision": revision }),
                            );
                        }
                        Ok(_) => {
                            lease.settle_failed("OPEN_WEBUI_GATEWAY_STATE_MISSING");
                        }
                        Err(error) => {
                            tracing::error!(%error, "could not persist Open WebUI update state");
                            lease.settle_failed("OPEN_WEBUI_GATEWAY_STATE_FAILED");
                        }
                    }
                }
                Ok(response) => {
                    lease.settle_failed(&response.code);
                }
                Err(error) => {
                    tracing::error!(%error, "Open WebUI update boundary failed");
                    lease.settle_failed("OPEN_WEBUI_UPDATE_FAILED");
                }
            }
        },
    )
    .await
}

/// Schedule bounded repair only after signed owner presence; reads never restart services and privd rechecks ownership/stop state.
pub async fn repair_open_webui(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let recipe = recipe(&state)?;
    let client = privileged(&state)?;
    let database = state.database.clone().ok_or_else(|| {
        envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "OPTIONAL_SERVICES_UNAVAILABLE",
            "optional service state is unavailable",
        )
    })?;
    let configured = database
        .lock()
        .query_row(
            "SELECT enabled OR pending_install FROM optional_services WHERE service_id = ?1",
            [SERVICE_ID],
            |row| row.get::<_, bool>(0),
        )
        .unwrap_or(false);
    if !configured {
        return Err(envelope(
            StatusCode::CONFLICT,
            "OPEN_WEBUI_GATEWAY_STATE_MISSING",
            "Open WebUI needs its existing scoped gateway before repair; preserve its data and inspect the local service state",
        ));
    }
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/services/open-webui/repair",
        "service.open_webui.repair",
        json!({"service_id": SERVICE_ID, "recipe_revision": recipe.metadata.revision}),
        None,
        move |operation_id, lease| {
            let result = client.call_bounded(
                PrivilegedOperation::RepairOpenWebUi {
                    request_id: operation_id,
                },
                std::time::Duration::from_secs(220),
            );
            match result {
                Ok(response) if response.accepted => {
                    let updated = database.lock().execute(
                        "UPDATE optional_services
                            SET enabled = 1, pending_install = 0,
                                updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                          WHERE service_id = ?1 AND (enabled = 1 OR pending_install = 1)",
                        [SERVICE_ID],
                    );
                    if matches!(updated, Ok(1)) {
                        let _ =
                            lease.succeed(&json!({"service_id": SERVICE_ID, "state": "healthy"}));
                    } else {
                        lease.settle_failed("OPEN_WEBUI_GATEWAY_STATE_FAILED");
                    }
                }
                Ok(response) => {
                    lease.settle_failed(&response.code);
                }
                Err(error) => {
                    tracing::error!(%error, "Open WebUI repair boundary failed");
                    lease.settle_failed("OPEN_WEBUI_REPAIR_FAILED");
                }
            }
        },
    )
    .await
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RemoveOpenWebUiRequest {
    #[serde(default)]
    pub(super) erase_data: bool,
}

pub async fn remove_open_webui(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<RemoveOpenWebUiRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    recipe(&state)?;
    let client = privileged(&state)?;
    let erase_data = request.erase_data;
    let database = state.database.clone().ok_or_else(|| {
        envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "OPTIONAL_SERVICES_UNAVAILABLE",
            "optional service state is unavailable",
        )
    })?;
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/services/open-webui/remove",
        "service.open_webui.remove",
        json!({ "service_id": SERVICE_ID, "erase_data": erase_data }),
        None,
        move |operation_id, lease| {
            let result = client.call(PrivilegedOperation::RemoveOpenWebUi {
                request_id: operation_id,
                erase_data,
            });
            match result {
                Ok(response) if response.accepted => {
                    if let Err(error) = disable_gateway(database.as_ref()) {
                        tracing::error!(%error, "could not disable Open WebUI gateway state");
                        lease.settle_failed("OPEN_WEBUI_GATEWAY_STATE_FAILED");
                    } else {
                        lease.settle_succeeded(
                            &json!({ "service_id": SERVICE_ID, "erase_data": erase_data }),
                        );
                    }
                }
                Ok(response) => {
                    lease.settle_failed(&response.code);
                }
                Err(error) => {
                    tracing::error!(%error, "Open WebUI removal boundary failed");
                    lease.settle_failed("OPEN_WEBUI_REMOVE_FAILED");
                }
            }
        },
    )
    .await
}
