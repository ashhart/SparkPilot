use super::*;

/// Map a persisted build row to its API document.
pub(super) fn build_job(row: &crate::store::BuildRow) -> Value {
    let result: Value = serde_json::from_str(&row.result_json).unwrap_or(Value::Null);
    json!({
        "build_id": row.id.to_string(),
        "project_id": row.project_id.to_string(),
        "worker_id": row.worker_id.map(|w| w.to_string()),
        "commit": row.commit_sha,
        "source_sha256": row.source_sha256,
        "status": row.status,
        "result": if row.result_json == "{}" { Value::Null } else { result },
        "created_at": row.created_at,
        "updated_at": row.updated_at,
    })
}

#[derive(serde::Deserialize)]
pub struct SubmitBuildBody {
    #[serde(rename = "projectId")]
    pub project_id: Uuid,
    pub commit: String,
    pub source_sha256: String,
    pub scheme: Option<String>,
    pub configuration: Option<String>,
    pub destination: Option<String>,
    pub actions: Option<Vec<String>>,
    pub timeout_seconds: Option<i64>,
    #[serde(default)]
    pub requirements: BuildRequirements,
}

/// Submit a durable build and return HTTP 202.
pub async fn submit_build(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    axum::Json(body): axum::Json<SubmitBuildBody>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let (Some(builds), Some(projects)) =
        (state.builds.service.clone(), state.projects.manager.clone())
    else {
        return Err(internal("build service unavailable"));
    };

    let project = projects
        .get(&body.project_id)
        .map_err(|e| service_error(&e))?;
    // Require write permission in the project whose source the build checks out.
    state
        .require(&principal, Capability::BuildSubmit)
        .in_project(project.id)
        .resource(format!("project/{}/builds", project.id))
        .check()?;

    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal("no database"))?;
    let mut conn = database.lock();
    let outcome = state
        .idempotency
        .execute(&mut conn, &idempotency, |transaction| {
            let operation_id = Uuid::new_v4();
            if let Err(error) = builds.submit_build_in(
                transaction,
                operation_id,
                &project,
                &body.commit,
                &body.source_sha256,
                body.scheme.as_deref().unwrap_or("SparkApp"),
                body.configuration.as_deref().unwrap_or("Debug"),
                body.destination.as_deref().unwrap_or("platform=macOS"),
                body.actions.clone().unwrap_or_else(|| vec!["build".into()]),
                body.timeout_seconds.unwrap_or(1800),
                &body.requirements,
                &principal.device_id,
            ) {
                let (status, Json(body)) = service_error(&error);
                return Ok(StoredResponse {
                    status,
                    body,
                    operation_id: None,
                });
            }
            let operation = state
                .jobs
                .get(transaction, operation_id)?
                .ok_or(crate::store::StoreError::NotFound("operation"))?;
            Ok(StoredResponse {
                status: StatusCode::ACCEPTED,
                body: serde_json::to_value(operation)
                    .map_err(|error| crate::store::StoreError::Sqlite(error.to_string()))?,
                operation_id: Some(operation_id),
            })
        })
        .map_err(|error| error.envelope())?;
    Ok(json_response(&outcome))
}

/// Authorize build metadata using the job's stored project ownership.
pub async fn get_build(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Path(build_id): Path<Uuid>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let Some(builds) = state.builds.service.clone() else {
        return Err(internal("build service unavailable"));
    };
    let row = builds
        .get_build(&build_id)
        .map_err(|e| envelope("BUILD_NOT_FOUND", &e, StatusCode::NOT_FOUND))?;
    state
        .require(&principal, Capability::BuildRead)
        .in_project(row.project_id)
        .resource(format!("build/{build_id}"))
        .check()
        // Conceal existing build IDs from nonmembers with the same not-found response as missing IDs.
        .map_err(|_| envelope("BUILD_NOT_FOUND", "no such build", StatusCode::NOT_FOUND))?;
    Ok(Json(build_job(&row)))
}

/// Poll the outbound worker claim channel.
pub async fn claim_build(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    Path(worker_id): Path<Uuid>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::BuildClaim)
        .resource(format!("build_worker/{worker_id}/claims"))
        .check()?;
    let Some(builds) = state.builds.service.clone() else {
        return Err(internal("build service unavailable"));
    };
    let _admission = state.idempotency.admission_guard();
    // Reconstruct claims from their request IDs without persisting secrets in generic idempotency responses.
    match builds.claim_next(&worker_id, &principal.device_id, &idempotency.key) {
        Ok(Some(recipe)) => Ok((
            StatusCode::OK,
            Json(serde_json::to_value(&recipe).map_err(|error| internal(&error.to_string()))?),
        )),
        Ok(None) => Err(envelope(
            "BUILD_NOTHING_QUEUED",
            "no queued builds",
            StatusCode::NOT_FOUND,
        )),
        Err(error) => {
            let status = match error.as_str() {
                "BUILD_WORKER_AT_CAPACITY" => StatusCode::CONFLICT,
                "BUILD_WORKER_OFFLINE" => StatusCode::SERVICE_UNAVAILABLE,
                "BUILD_WORKER_FORBIDDEN" | "BUILD_WORKER_NOT_FOUND" => StatusCode::FORBIDDEN,
                _ => StatusCode::INTERNAL_SERVER_ERROR,
            };
            Err(envelope(&error, "the worker cannot claim this job", status))
        }
    }
}

pub async fn renew_claim(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    _idempotency: IdempotencyRequest,
    Path(build_id): Path<Uuid>,
    headers: axum::http::HeaderMap,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::BuildClaim)
        .resource(format!("build/{build_id}/lease"))
        .check()?;
    let builds = state
        .builds
        .service
        .clone()
        .ok_or_else(|| internal("build service unavailable"))?;
    let _admission = state.idempotency.admission_guard();
    let worker_id = worker_for_device(&builds, &build_id, &principal.device_id)?;
    let token = header(&headers, HEADER_BUILD_CLAIM);
    let (expires_at, cancel_requested) = builds
        .renew_claim(&build_id, &worker_id, token)
        .map_err(claim_error)?;
    Ok((
        StatusCode::OK,
        Json(json!({
            "build_id": build_id,
            "worker_id": worker_id,
            "expires_at": expires_at,
            "cancel_requested": cancel_requested,
        })),
    ))
}

/// Require build.report capability and the current worker's claim proof before accepting a result.
pub async fn report_result(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    _idempotency: IdempotencyRequest,
    Path(build_id): Path<Uuid>,
    headers: axum::http::HeaderMap,
    axum::Json(body): axum::Json<SignedBuildResult>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::BuildReport)
        .resource(format!("build/{build_id}/result"))
        .check()?;
    let Some(builds) = state.builds.service.clone() else {
        return Err(internal("build service unavailable"));
    };
    let _admission = state.idempotency.admission_guard();
    let worker_id = worker_for_device(&builds, &build_id, &principal.device_id)?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal("no database"))?;
    let device = crate::store::load_device_by_id(&database.lock(), &principal.device_id)
        .map_err(|error| internal(&error.to_string()))?
        .ok_or_else(|| {
            envelope(
                "DEVICE_NOT_FOUND",
                "paired device missing",
                StatusCode::UNAUTHORIZED,
            )
        })?;
    match builds.record_result(
        &build_id,
        &worker_id,
        header(&headers, HEADER_BUILD_CLAIM),
        &device.public_key_spki,
        &body,
    ) {
        Ok(row) => Ok((StatusCode::OK, Json(build_job(&row)))),
        Err(code) => Err(claim_error(code)),
    }
}

pub(super) fn claim_error(code: &'static str) -> (StatusCode, Json<Value>) {
    let status = match code {
        "BUILD_NOT_FOUND" => StatusCode::NOT_FOUND,
        "BUILD_CLAIM_EXPIRED" | "BUILD_CLAIM_LOST" | "BUILD_CANCELLATION_PENDING" => {
            StatusCode::CONFLICT
        }
        "BUILD_RESULT_INVALID"
        | "BUILD_RESULT_BINDING_MISMATCH"
        | "BUILD_RESULT_HASH_MISMATCH"
        | "BUILD_RESULT_TIME_INVALID"
        | "BUILD_RESULT_PROTOCOL_UNSUPPORTED"
        | "BUILD_ARTIFACT_LIMIT_EXCEEDED"
        | "BUILD_ARTIFACT_PATH_INVALID" => StatusCode::UNPROCESSABLE_ENTITY,
        "BUILD_RESULT_STORE_FAILED" | "BUILD_OPERATION_INVALID" => {
            StatusCode::INTERNAL_SERVER_ERROR
        }
        _ => StatusCode::FORBIDDEN,
    };
    envelope(code, "the worker evidence was refused", status)
}
