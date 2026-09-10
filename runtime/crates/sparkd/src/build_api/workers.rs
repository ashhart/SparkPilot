use super::*;

/// Require worker-read capability and restrict nonoperators to their own registered workers.
pub async fn list_workers(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::BuildWorkerRead)
        .resource("build_workers")
        .check()?;
    let Some(builds) = state.builds.service.clone() else {
        return Err(internal("build service unavailable"));
    };
    let operator =
        crate::capability::Role::parse(&principal.role) >= crate::capability::Role::Developer;
    let rows = builds.list_workers().map_err(|e| internal(&e))?;
    let items: Vec<Value> = rows
        .iter()
        .filter(|row| operator || row.device_id == principal.device_id)
        .map(|row| {
            json!({
                "worker_id": row.id.to_string(),
                "display_name": row.display_name,
                "state": row.state,
                "platform": "macOS",
                "xcode_version": row.xcode_version,
                "capabilities": serde_json::from_str::<Value>(&row.capabilities_json)
                    .unwrap_or(json!({})),
                "last_seen_at": row.last_seen_at,
                "heartbeat_expires_at": row.heartbeat_expires_at,
            })
        })
        .collect();
    Ok(Json(json!({ "items": items })))
}

#[derive(serde::Deserialize)]
pub struct WorkerRegistrationBody {
    pub worker_id: Uuid,
    pub platform: String,
    pub xcode_version: String,
    pub sdk_versions: Option<Vec<String>>,
    pub architectures: Option<Vec<String>>,
    pub simulators: Option<Vec<String>>,
    pub signing_available: Option<bool>,
    pub max_concurrent_jobs: Option<u32>,
}

/// Register the calling device's Mac worker.
pub async fn register_worker(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    axum::Json(body): axum::Json<WorkerRegistrationBody>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::BuildWorkerRegister)
        .resource("build_workers")
        .check()?;
    if body.platform != "macOS" {
        return Err(envelope(
            "WORKER_PLATFORM_UNSUPPORTED",
            "build workers run on macOS (§43)",
            StatusCode::UNPROCESSABLE_ENTITY,
        ));
    }
    let architectures = body.architectures.unwrap_or_else(|| vec!["arm64".into()]);
    let sdk_versions = body.sdk_versions.unwrap_or_default();
    let simulators = body.simulators.unwrap_or_default();
    let concurrency = body.max_concurrent_jobs.unwrap_or(1);
    let valid_architectures = architectures.iter().all(|value| {
        !value.is_empty() && value.len() <= 64 && !value.chars().any(char::is_control)
    });
    let valid_toolchain_values = sdk_versions.iter().chain(simulators.iter()).all(|value| {
        !value.is_empty() && value.len() <= 200 && !value.chars().any(char::is_control)
    });
    if architectures.is_empty()
        || architectures.len() > 16
        || sdk_versions.len() > 64
        || simulators.len() > 128
        || !(1..=8).contains(&concurrency)
        || !valid_architectures
        || !valid_toolchain_values
        || body.xcode_version.is_empty()
        || body.xcode_version.len() > 64
        || body.xcode_version.chars().any(char::is_control)
    {
        return Err(envelope(
            "BUILD_WORKER_CAPABILITIES_INVALID",
            "worker capabilities are outside the supported bounds",
            StatusCode::UNPROCESSABLE_ENTITY,
        ));
    }
    let Some(builds) = state.builds.service.clone() else {
        return Err(internal("build service unavailable"));
    };
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal("no database"))?;
    let _admission = state.idempotency.admission_guard();
    if let Some(outcome) = state
        .idempotency
        .lookup(&mut database.lock(), &idempotency)
        .map_err(|error| error.envelope())?
    {
        return if outcome.response.status.is_success() {
            Ok(json_response(&outcome))
        } else {
            Err(json_response(&outcome))
        };
    }
    let capabilities = json!({
        "architectures": architectures,
        "simulators": simulators,
        "sdk_versions": sdk_versions,
        "signing_available": body.signing_available.unwrap_or(false),
        "max_concurrent_jobs": concurrency,
    });
    let response = match builds.register_worker(
        &format!("Mac of {}", &principal.device_id.to_string()[..8]),
        &principal.device_id,
        &body.xcode_version,
        "macOS",
        &capabilities,
        Some(body.worker_id),
    ) {
        Ok(row) => StoredResponse {
            status: StatusCode::ACCEPTED,
            body: json!({
                "worker_id": row.id.to_string(),
                "display_name": row.display_name,
                "state": row.state,
                "platform": "macOS",
                "xcode_version": row.xcode_version,
                "capabilities": capabilities,
            }),
            operation_id: None,
        },
        Err(error) => {
            let (status, Json(body)) = internal(&error);
            StoredResponse {
                status,
                body,
                operation_id: None,
            }
        }
    };
    let outcome = state
        .idempotency
        .execute(&mut database.lock(), &idempotency, |_| Ok(response))
        .map_err(|error| error.envelope())?;
    Ok(json_response(&outcome))
}

pub async fn heartbeat_worker(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    Path(worker_id): Path<Uuid>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::BuildClaim)
        .resource(format!("build_worker/{worker_id}/heartbeat"))
        .check()?;
    let builds = state
        .builds
        .service
        .clone()
        .ok_or_else(|| internal("build service unavailable"))?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal("no database"))?;
    let _admission = state.idempotency.admission_guard();
    if let Some(outcome) = state
        .idempotency
        .lookup(&mut database.lock(), &idempotency)
        .map_err(|error| error.envelope())?
    {
        return Ok(json_response(&outcome));
    }
    let active = builds
        .heartbeat(&worker_id, &principal.device_id)
        .map_err(|code| envelope(&code, "worker heartbeat refused", StatusCode::FORBIDDEN))?;
    let response = StoredResponse {
        status: StatusCode::OK,
        body: json!({
            "worker_id": worker_id,
            "state": if active == 0 { "online" } else { "busy" },
            "active_jobs": active,
            "heartbeat_seconds": crate::build::HEARTBEAT_SECONDS,
        }),
        operation_id: None,
    };
    let outcome = state
        .idempotency
        .execute(&mut database.lock(), &idempotency, |_| Ok(response))
        .map_err(|error| error.envelope())?;
    Ok(json_response(&outcome))
}

pub(super) fn worker_for_device(
    builds: &crate::build::BuildService,
    build_id: &Uuid,
    device_id: &Uuid,
) -> Result<Uuid, (StatusCode, Json<Value>)> {
    let build = builds
        .get_build(build_id)
        .map_err(|_| envelope("BUILD_NOT_FOUND", "no such build", StatusCode::NOT_FOUND))?;
    let worker_id = build.worker_id.ok_or_else(|| {
        envelope(
            "BUILD_NOT_CLAIMED",
            "the build has no active worker",
            StatusCode::CONFLICT,
        )
    })?;
    if builds
        .worker_owner(&worker_id)
        .map_err(|error| internal(&error))?
        != Some(*device_id)
    {
        return Err(envelope(
            "BUILD_CLAIM_INVALID",
            "the build belongs to another worker",
            StatusCode::FORBIDDEN,
        ));
    }
    Ok(worker_id)
}
