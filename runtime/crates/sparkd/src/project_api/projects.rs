use super::*;

pub(super) fn project_capabilities(
    state: &AppState,
    principal: &Principal,
    project_id: uuid::Uuid,
) -> Result<Vec<&'static str>, (StatusCode, Json<Value>)> {
    let Some(database) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    let permission =
        crate::store::project_permission(&database.lock(), &project_id, &principal.device_id)
            .map_err(|error| internal_envelope(&error.to_string()))?
            .as_deref()
            .and_then(ProjectPermission::parse);
    let role = Role::parse(&principal.role);
    let candidates = [
        (Capability::ProjectReadOwn, "read"),
        (Capability::ProjectFileWrite, "write"),
        (Capability::ProjectTerminal, "terminal"),
        (Capability::ProjectPreview, "preview"),
        (Capability::AgentRun, "agent_run"),
        (Capability::AgentChangeApprove, "review"),
        (Capability::ProjectDelete, "delete"),
    ];
    Ok(candidates
        .into_iter()
        .filter_map(|(capability, name)| {
            if capability == Capability::AgentRun && !state.agents.execution_available {
                return None;
            }
            evaluate(&Request {
                capability,
                scope: ResourceScope::Project { project_id },
                role,
                device_id: principal.device_id,
                project_permission: permission,
                presence: Presence::Absent,
                policy: state.capability_policy,
            })
            .is_ok()
            .then_some(name)
        })
        .collect())
}

pub(super) fn project_json(
    state: &AppState,
    principal: &Principal,
    view: crate::project::ProjectView,
) -> Result<Value, (StatusCode, Json<Value>)> {
    let capabilities = project_capabilities(state, principal, view.id)?;
    let mut value =
        serde_json::to_value(view.dto()).map_err(|error| internal_envelope(&error.to_string()))?;
    value["capabilities"] = json!(capabilities);
    value["harness_updates"] = json!(super::development::harness_updates(state, &view));
    Ok(value)
}

pub(super) fn collection_capabilities(
    state: &AppState,
    principal: &Principal,
) -> Vec<&'static str> {
    evaluate(&Request {
        capability: Capability::ProjectCreate,
        scope: ResourceScope::Node,
        role: Role::parse(&principal.role),
        device_id: principal.device_id,
        project_permission: None,
        presence: Presence::Absent,
        policy: state.capability_policy,
    })
    .is_ok()
    .then_some(vec!["create"])
    .unwrap_or_default()
}

/// Filter project listings by membership even when the caller has a higher node-wide role.
pub async fn list_projects(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Response, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ProjectList)
        .resource("projects")
        .check()?;
    let Some(manager) = &state.projects.manager else {
        return Err(internal_envelope("project service unavailable"));
    };
    let Some(database) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    let visible = {
        let conn = database.lock();
        crate::store::project_ids_for_device(&conn, &principal.device_id)
            .map_err(|error| internal_envelope(&error.to_string()))?
    };
    let items: Result<Vec<_>, _> = manager
        .list()
        .map_err(|e| internal_envelope(&e))?
        .into_iter()
        .filter(|project| visible.contains(&project.id))
        .map(|project| project_json(&state, &principal, project))
        .collect();
    // Clients require this marker because older daemons left durable workspaces behind after DELETE.
    Ok((
        [("x-spark-project-deletion", "complete-v1")],
        Json(json!({
            "items": items?,
            "next_cursor": null,
            "capabilities": collection_capabilities(&state, &principal),
        })),
    )
        .into_response())
}

#[derive(serde::Deserialize)]
pub struct CreateProjectBody {
    pub name: String,
    #[serde(default)]
    pub repository_url: Option<String>,
    #[serde(default)]
    pub revision: Option<String>,
    #[serde(default)]
    pub template_id: Option<String>,
}

/// `POST /api/v1/projects` — 202 + durable creation operation.
pub async fn create_project(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    Json(body): Json<CreateProjectBody>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ProjectCreate)
        .resource("projects")
        .check()?;
    // ProjectCreate does not authorize client-selected service-readable local mirrors or protected repositories.
    if let Some(repository_url) = body.repository_url.as_deref()
        && (spark_project_runner::worktree::validate_repository_url(repository_url).is_err()
            || !reqwest::Url::parse(repository_url).is_ok_and(|url| {
                url.scheme() == "https"
                    && url.host_str().is_some()
                    && url.username().is_empty()
                    && url.password().is_none()
                    && url.fragment().is_none()
            }))
    {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({ "error": {
                "code": "REPOSITORY_URL_UNSUPPORTED",
                "message": "Repository URLs must use HTTPS without credentials or fragments."
            }})),
        ));
    }
    if body.template_id.is_some() {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(
                json!({ "error": { "code": "TEMPLATE_UNAVAILABLE", "message": "templates are not available in this revision" } }),
            ),
        ));
    }
    let Some(manager) = &state.projects.manager else {
        return Err(internal_envelope("project service unavailable"));
    };
    let Some(db) = &state.database else {
        return Err(internal_envelope("no database"));
    };

    let outcome = {
        let mut conn = db.lock();
        state
            .idempotency
            .create_operation(
                &mut conn,
                &idempotency,
                &state.jobs,
                "project.create",
                None,
                &json!({
                    "name": body.name,
                    "repository_url": body.repository_url,
                    "revision": body.revision
                })
                .to_string(),
            )
            .map_err(|error| error.envelope())?
    };
    if !outcome.created {
        return Ok(json_response(&outcome));
    }
    let operation_id = outcome.response.operation_id.unwrap();

    let manager = manager.clone();
    let name = body.name.clone();
    let url = body.repository_url.clone();
    let revision = body.revision.clone();
    state
        .jobs
        .spawn_leased(db.clone(), operation_id, move |lease| {
            let result = manager.create_project(
                operation_id,
                &name,
                url.as_deref(),
                revision.as_deref(),
                &principal.device_id,
            );
            match result {
                Ok(()) => {
                    lease.settle_succeeded(&json!({ "created": true, "name": name }));
                }
                Err(e) => {
                    lease.settle_failed(&e);
                }
            }
        })
        .map_err(|error| crate::api_error::spawn_envelope(&error))?;

    Ok(json_response(&outcome))
}

/// `GET /api/v1/projects/{projectId}`.
pub async fn get_project(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    RoutePath(project_id): RoutePath<uuid::Uuid>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ProjectReadOwn)
        .in_project(project_id)
        .resource(format!("project/{project_id}"))
        .check()?;
    let view = project(&project_id, &state)?;
    Ok(Json(project_json(&state, &principal, view)?))
}

/// `DELETE /api/v1/projects/{projectId}` — 202 + durable deletion.
pub async fn delete_project(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    RoutePath(project_id): RoutePath<uuid::Uuid>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let Some(manager) = &state.projects.manager else {
        return Err(internal_envelope("project service unavailable"));
    };
    let Some(db) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    // Replay scoped accepted deletes before membership checks because successful deletion removes the membership required for fresh authorization.
    let _admission = state.idempotency.admission_guard();
    if let Some(replay) = state
        .idempotency
        .lookup(&mut db.lock(), &idempotency)
        .map_err(|error| error.envelope())?
    {
        return if replay.response.status.is_success() {
            Ok(json_response(&replay))
        } else {
            Err(json_response(&replay))
        };
    }
    // Require administrator membership in the project; global role cannot authorize project deletion.
    state
        .require(&principal, Capability::ProjectDelete)
        .in_project(project_id)
        .resource(format!("project/{project_id}"))
        .check()?;
    let outcome = {
        let mut conn = db.lock();
        state
            .idempotency
            .execute(&mut conn, &idempotency, |transaction| {
                let operation_id = state.jobs.create(
                    transaction,
                    "project.delete",
                    principal.device_id,
                    None,
                    &json!({ "project_id": project_id }).to_string(),
                )?;
                let operation = state
                    .jobs
                    .get(transaction, operation_id)?
                    .ok_or(crate::store::StoreError::NotFound("operation"))?;
                Ok(crate::idempotency::StoredResponse {
                    status: StatusCode::ACCEPTED,
                    body: serde_json::to_value(operation)
                        .map_err(|error| crate::store::StoreError::Sqlite(error.to_string()))?,
                    operation_id: Some(operation_id),
                })
            })
            .map_err(|error| error.envelope())?
    };
    if !outcome.created || !outcome.response.status.is_success() {
        if outcome.response.status.is_success() {
            return Ok(json_response(&outcome));
        }
        return Err(json_response(&outcome));
    }
    let operation_id = outcome.response.operation_id.unwrap();
    let manager = manager.clone();
    state
        .jobs
        .spawn_leased(db.clone(), operation_id, move |lease| {
            let result = manager.delete_project(operation_id, &project_id);
            match result {
                Ok(()) => {
                    lease.settle_succeeded(&json!({ "deleted": true }));
                }
                Err(e) => {
                    lease.settle_failed(&e);
                }
            }
        })
        .map_err(|error| crate::api_error::spawn_envelope(&error))?;
    Ok(json_response(&outcome))
}
