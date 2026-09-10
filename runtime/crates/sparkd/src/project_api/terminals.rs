use super::*;

pub(super) fn terminal_not_found() -> (StatusCode, Json<Value>) {
    (
        StatusCode::NOT_FOUND,
        Json(json!({ "error": { "code": "TERMINAL_NOT_FOUND", "message": "TERMINAL_NOT_FOUND" } })),
    )
}

pub(super) fn sandbox_unavailable(detail: &str) -> (StatusCode, Json<Value>) {
    let code = if detail.starts_with("PROJECT_SANDBOX_UNAVAILABLE") {
        "PROJECT_SANDBOX_UNAVAILABLE"
    } else {
        "PROJECT_SANDBOX_START_FAILED"
    };
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({ "error": { "code": code, "message": detail } })),
    )
}

/// Resolve only within the authorized project and hide nonexistent versus foreign sessions behind TERMINAL_NOT_FOUND.
pub(super) fn resolve_terminal(
    state: &AppState,
    principal: &Principal,
    project_id: &uuid::Uuid,
    terminal_id: &uuid::Uuid,
) -> Result<crate::project::TerminalRecord, (StatusCode, Json<Value>)> {
    let Some(manager) = &state.projects.manager else {
        return Err(internal_envelope("project service unavailable"));
    };
    match manager.terminal(project_id, terminal_id) {
        Ok(record) => Ok(record),
        Err(crate::project::TerminalLookupError::WrongProject) => {
            tracing::warn!(
                device_id = %principal.device_id,
                %project_id,
                %terminal_id,
                "refused a terminal addressed through the wrong project"
            );
            Err(terminal_not_found())
        }
        Err(crate::project::TerminalLookupError::NotFound) => Err(terminal_not_found()),
        Err(crate::project::TerminalLookupError::CloseFailed) => Err(internal_envelope(
            "The Spark could not confirm that the session stopped. Try End Session again.",
        )),
    }
}

/// Create container-only terminals from enumerated shells; the privileged helper selects argv rather than accepting commands.
pub async fn create_terminal(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    RoutePath(project_id): RoutePath<uuid::Uuid>,
    Json(body): Json<serde_json::Value>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ProjectTerminal)
        .in_project(project_id)
        .resource(format!("project/{project_id}/terminals"))
        .check()?;

    if body.get("command").is_some() {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({
                "error": {
                    "code": "COMMAND_NOT_SUPPORTED",
                    "message": "terminals name a shell, not a command; use \"shell\": one of login, bash, python"
                }
            })),
        ));
    }
    let shell = match body.get("shell").and_then(Value::as_str) {
        None => spark_project_runner::TerminalShell::Login,
        Some(name) => match spark_project_runner::TerminalShell::parse(name) {
            Some(shell) => shell,
            None => {
                return Err((
                    StatusCode::UNPROCESSABLE_ENTITY,
                    Json(json!({
                        "error": {
                            "code": "SHELL_NOT_SUPPORTED",
                            "message": "shell must be one of login, bash, python"
                        }
                    })),
                ));
            }
        },
    };

    let development = if shell == spark_project_runner::TerminalShell::Development {
        Some(serde_json::from_value::<super::development::DevelopmentLaunch>(body.get("development").cloned().unwrap_or(Value::Null))
            .map_err(|_| (StatusCode::UNPROCESSABLE_ENTITY, Json(json!({"error":{"code":"DEVELOPMENT_SELECTION_REQUIRED","message":"Choose a harness and running Spark model."}}))))?)
    } else {
        if body.get("development").is_some() {
            return Err((
                StatusCode::UNPROCESSABLE_ENTITY,
                Json(
                    json!({"error":{"code":"DEVELOPMENT_SHELL_REQUIRED","message":"A development selection requires the development shell."}}),
                ),
            ));
        }
        None
    };

    let Some(manager) = &state.projects.manager else {
        return Err(internal_envelope("project service unavailable"));
    };
    let view = project(&project_id, &state)?;
    let columns = body
        .get("cols")
        .and_then(Value::as_u64)
        .unwrap_or(120)
        .clamp(1, 500) as u16;
    let rows = body
        .get("rows")
        .and_then(Value::as_u64)
        .unwrap_or(40)
        .clamp(1, 250) as u16;
    let Some(database) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    let _admission = state.idempotency.admission_guard();
    if let Some(replay) = state
        .idempotency
        .lookup(&mut database.lock(), &idempotency)
        .map_err(|error| error.envelope())?
    {
        return if replay.response.status.is_success() {
            Ok(json_response(&replay))
        } else {
            Err(json_response(&replay))
        };
    }
    let terminal_id = uuid::Uuid::new_v4();
    let _reservation = manager
        .reserve_terminal(project_id, terminal_id)
        .map_err(|error| sandbox_unavailable(&error))?;
    let outcome = state
        .idempotency
        .execute(&mut database.lock(), &idempotency, |_transaction| {
            Ok(StoredResponse {
                status: StatusCode::ACCEPTED,
                body: json!({
                    "terminal_id": terminal_id.to_string(),
                    "project_id": project_id.to_string(),
                    "shell": shell.name(),
                    "state": if development.is_some() { "starting" } else { "running" },
                    "created_at": state.clock.now_rfc3339(),
                    "ws_url": format!("/api/v1/projects/{project_id}/terminals/{terminal_id}/ws"),
                }),
                operation_id: None,
            })
        })
        .map_err(|error| error.envelope())?;
    drop(_admission);
    if outcome.created {
        if let Some(launch) = development {
            // First-use image preparation outlives an HTTP request; the app polls this same reserved identity.
            let state = state.clone();
            let manager = manager.clone();
            let mut response = outcome.response.clone();
            tokio::spawn(async move {
                let _reservation = _reservation;
                let creation = match super::development::prepare(
                    &state,
                    &principal,
                    &view,
                    terminal_id,
                    launch,
                )
                .await
                {
                    Ok(container) => manager.development_terminal_create(
                        terminal_id,
                        project_id,
                        principal.device_id,
                        columns,
                        rows,
                        container,
                    ),
                    Err(error) => Err(error),
                };
                match creation {
                    Ok(record) => {
                        persist_created_terminal(&state, &record);
                        response.body["state"] = json!("running");
                    }
                    Err(error) if error == "TERMINAL_LAUNCH_CANCELLED" => {
                        response.body["state"] = json!("stopped");
                    }
                    Err(error) => {
                        tracing::warn!(%terminal_id, %error, "development session preparation failed");
                        manager.mark_terminal_failed(project_id, terminal_id, error.clone());
                        response.body["state"] = json!("failed");
                        response.body["message"] = json!(error);
                    }
                }
                if let Some(database) = &state.database
                    && let Err(error) = state.idempotency.replace_response(
                        &mut database.lock(),
                        &idempotency,
                        &response,
                        |_| Ok(()),
                    )
                {
                    tracing::error!(%terminal_id, %error, "development launch result could not be persisted");
                }
            });
            return Ok(json_response(&outcome));
        }
        let creation = manager.terminal_create(
            terminal_id,
            &view,
            principal.device_id,
            shell,
            columns,
            rows,
        );
        match creation {
            Ok(record) => persist_created_terminal(&state, &record),
            Err(error) => {
                let (status, Json(body)) = sandbox_unavailable(&error);
                let replacement = StoredResponse {
                    status,
                    body: body.clone(),
                    operation_id: None,
                };
                state
                    .idempotency
                    .replace_response(
                        &mut database.lock(),
                        &idempotency,
                        &replacement,
                        |_transaction| Ok(()),
                    )
                    .map_err(|error| error.envelope())?;
                return Err((status, Json(body)));
            }
        }
    }
    if outcome.response.status.is_success() {
        Ok(json_response(&outcome))
    } else {
        Err(json_response(&outcome))
    }
}

fn persist_created_terminal(state: &AppState, record: &crate::project::TerminalRecord) {
    let Some(database) = &state.database else {
        return;
    };
    let conn = database.lock();
    if let Err(error) = crate::store::insert_terminal(
        &conn,
        &record.terminal_id,
        &record.project_id,
        &record.creator_device_id,
        &record.container_id,
        record.shell.name(),
        &state.clock.now_rfc3339(),
    ) {
        tracing::error!(%error, "terminal record could not be persisted");
    }
    state.events.emit_scoped(Some(&conn), &state.identity.node_id().to_string(), None,
        "project.terminal.opened", "info", json!({ "project_id": record.project_id,
        "terminal_id": record.terminal_id, "container_id": record.container_id, "shell": record.shell.name() }),
        crate::events::Visibility::project(record.project_id));
}

/// Read state before restarting a saved workspace; an unavailable network is never evidence of process loss.
pub async fn terminal_state(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    RoutePath((project_id, terminal_id)): RoutePath<(uuid::Uuid, uuid::Uuid)>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ProjectTerminal)
        .in_project(project_id)
        .resource(format!("project/{project_id}/terminals/{terminal_id}"))
        .check()?;
    let manager = state
        .projects
        .manager
        .as_ref()
        .ok_or_else(|| internal_envelope("project service unavailable"))?;
    let status = manager
        .terminal_state(&project_id, &terminal_id)
        .ok_or_else(terminal_not_found)?;
    Ok(Json(
        json!({ "terminal_id": terminal_id, "project_id": project_id, "state": status,
        "message": manager.terminal_failure(&project_id, &terminal_id) }),
    ))
}

/// Reauthorize attachment against the owning project; another project's terminal id is never addressable.
pub async fn attach_terminal(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    RoutePath((project_id, terminal_id)): RoutePath<(uuid::Uuid, uuid::Uuid)>,
    // Bind identifying extractors before upgrade; malformed handshakes return the same 400 for all ids without leaking authorization state.
    upgrade: WebSocketUpgrade,
) -> Result<Response, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ProjectTerminal)
        .in_project(project_id)
        .resource(format!("project/{project_id}/terminals/{terminal_id}"))
        .check()?;
    let record = resolve_terminal(&state, &principal, &project_id, &terminal_id)?;
    let authorization =
        TerminalAuthorization::capture(&state, &principal, project_id).ok_or_else(|| {
            (
                StatusCode::FORBIDDEN,
                Json(json!({"error": {"code": "PERMISSION_DENIED"}})),
            )
        })?;
    Ok(upgrade
        .max_message_size(16 * 1024)
        .max_frame_size(16 * 1024)
        .on_upgrade(move |socket| drive_terminal(socket, record, state, authorization)))
}

/// `DELETE /api/v1/projects/{projectId}/terminals/{terminalId}` — close.
pub async fn close_terminal(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    RoutePath((project_id, terminal_id)): RoutePath<(uuid::Uuid, uuid::Uuid)>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ProjectTerminal)
        .in_project(project_id)
        .resource(format!("project/{project_id}/terminals/{terminal_id}"))
        .check()?;
    let Some(manager) = &state.projects.manager else {
        return Err(internal_envelope("project service unavailable"));
    };
    let Some(database) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    let _admission = state.idempotency.admission_guard();
    if let Some(replay) = state
        .idempotency
        .lookup(&mut database.lock(), &idempotency)
        .map_err(|error| error.envelope())?
    {
        return if replay.response.status.is_success() {
            Ok(json_response(&replay))
        } else {
            Err(json_response(&replay))
        };
    }
    // Resolve the project-bound terminal before storing replay evidence so a foreign id cannot hide a later refusal.
    if manager.terminal_state(&project_id, &terminal_id) != Some("starting")
        && manager.terminal_state(&project_id, &terminal_id) != Some("stopped")
    {
        resolve_terminal(&state, &principal, &project_id, &terminal_id)?;
    }
    match manager.terminal_close(&project_id, &terminal_id) {
        Ok(()) => {}
        Err(crate::project::TerminalLookupError::CloseFailed) => {
            return Err(internal_envelope(
                "The Spark could not confirm that the session stopped. Try End Session again.",
            ));
        }
        Err(_) => return Err(terminal_not_found()),
    }
    {
        let conn = database.lock();
        if let Err(error) = crate::store::close_terminal(
            &conn,
            &project_id,
            &terminal_id,
            &state.clock.now_rfc3339(),
        ) {
            tracing::error!(%error, "terminal record could not be closed");
        }
        state.events.emit_scoped(
            Some(&conn),
            &state.identity.node_id().to_string(),
            None,
            "project.terminal.closed",
            "info",
            json!({ "project_id": project_id, "terminal_id": terminal_id }),
            crate::events::Visibility::project(project_id),
        );
    }
    let outcome = state
        .idempotency
        .execute(&mut database.lock(), &idempotency, |_transaction| {
            Ok(StoredResponse {
                status: StatusCode::OK,
                body: json!({
                    "terminal_id": terminal_id.to_string(),
                    "project_id": project_id.to_string(),
                    "state": "closed",
                }),
                operation_id: None,
            })
        })
        .map_err(|error| error.envelope())?;
    Ok(json_response(&outcome))
}
