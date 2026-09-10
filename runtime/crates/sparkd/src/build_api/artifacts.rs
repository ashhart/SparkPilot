use super::*;

pub async fn upload_artifact(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    _idempotency: IdempotencyRequest,
    Path((build_id, artifact_id)): Path<(Uuid, Uuid)>,
    headers: axum::http::HeaderMap,
    body: Bytes,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::BuildReport)
        .resource(format!("build/{build_id}/artifact/{artifact_id}"))
        .check()?;
    let builds = state
        .builds
        .service
        .clone()
        .ok_or_else(|| internal("build service unavailable"))?;
    let _admission = state.idempotency.admission_guard();
    let worker_id = worker_for_device(&builds, &build_id, &principal.device_id)?;
    let evidence = BuildArtifactEvidence {
        artifact_id,
        kind: header(&headers, HEADER_ARTIFACT_KIND).to_owned(),
        relative_path: header(&headers, HEADER_ARTIFACT_PATH).to_owned(),
        sha256: header(&headers, HEADER_ARTIFACT_SHA256).to_owned(),
        size_bytes: body.len() as u64,
    };
    builds
        .store_artifact(
            &build_id,
            &worker_id,
            header(&headers, HEADER_BUILD_CLAIM),
            header(&headers, HEADER_ARTIFACT_TOKEN),
            &evidence,
            &body,
        )
        .map_err(|code| {
            envelope(
                code,
                "artifact upload was refused",
                StatusCode::UNPROCESSABLE_ENTITY,
            )
        })?;
    Ok((
        StatusCode::CREATED,
        Json(serde_json::to_value(evidence).unwrap_or(Value::Null)),
    ))
}

/// Authorize artifact downloads by project and verify digests without accepting worker-upload credentials.
pub async fn get_artifact(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Path((build_id, artifact_id)): Path<(Uuid, Uuid)>,
) -> Result<Response, (StatusCode, Json<Value>)> {
    let builds = state
        .builds
        .service
        .clone()
        .ok_or_else(|| internal("build service unavailable"))?;
    let build = builds
        .get_build(&build_id)
        .map_err(|_| envelope("BUILD_NOT_FOUND", "no such build", StatusCode::NOT_FOUND))?;
    state
        .require(&principal, Capability::BuildRead)
        .in_project(build.project_id)
        .resource(format!("build/{build_id}/artifact/{artifact_id}"))
        .check()
        .map_err(|_| envelope("BUILD_NOT_FOUND", "no such artifact", StatusCode::NOT_FOUND))?;
    let (artifact, bytes) = builds
        .read_artifact(&build_id, &artifact_id)
        .map_err(|code| {
            let status = if code == "BUILD_ARTIFACT_CORRUPT" {
                StatusCode::INTERNAL_SERVER_ERROR
            } else if code == "BUILD_ARTIFACT_NOT_READY" {
                StatusCode::CONFLICT
            } else {
                StatusCode::NOT_FOUND
            };
            envelope(code, "artifact unavailable", status)
        })?;
    Ok((
        StatusCode::OK,
        [
            ("content-type", "application/octet-stream"),
            ("cache-control", "private, no-store"),
            (HEADER_ARTIFACT_SHA256, artifact.sha256.as_str()),
        ],
        bytes,
    )
        .into_response())
}
