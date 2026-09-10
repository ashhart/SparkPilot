use super::*;

/// `GET /api/v1/projects/{projectId}/files` — §42.8 browse.
pub async fn list_files(
    State(state): State<AppState>,
    axum::extract::Query(workspace): axum::extract::Query<WorkspaceQuery>,
    Extension(principal): Extension<Principal>,
    RoutePath(project_id): RoutePath<uuid::Uuid>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ProjectFileRead)
        .in_project(project_id)
        .resource(format!("project/{project_id}/files"))
        .check()?;
    let view = workspace_view(project(&project_id, &state)?, &state, &workspace)?;
    let Some(manager) = &state.projects.manager else {
        return Err(internal_envelope("project service unavailable"));
    };
    let items = manager
        .file_list(&view)
        .map_err(|e| internal_envelope(&e))?;
    Ok(Json(json!({ "items": items })))
}

/// Return file content and revision from one coherent snapshot for optimistic editing.
pub async fn read_file(
    State(state): State<AppState>,
    axum::extract::Query(workspace): axum::extract::Query<WorkspaceQuery>,
    Extension(principal): Extension<Principal>,
    RoutePath((project_id, relative)): RoutePath<(uuid::Uuid, String)>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ProjectFileRead)
        .in_project(project_id)
        .resource(format!("project/{project_id}/files/{relative}"))
        .check()?;
    let view = workspace_view(project(&project_id, &state)?, &state, &workspace)?;
    let Some(manager) = &state.projects.manager else {
        return Err(internal_envelope("project service unavailable"));
    };
    match manager.file_read(&view, &relative) {
        Ok(bytes) => {
            let content = String::from_utf8(bytes.clone()).map_err(|_| {
                (
                    StatusCode::UNSUPPORTED_MEDIA_TYPE,
                    Json(json!({
                        "error": {
                            "code": "FILE_NOT_TEXT",
                            "message": "the editor only reads UTF-8 text files"
                        }
                    })),
                )
            })?;
            Ok(Json(json!({
                "path": relative,
                "content": content,
                "revision": crate::project::revision_of(&bytes),
            })))
        }
        Err(error) if error.starts_with("FILE_NOT_FOUND:") => Err((
            StatusCode::NOT_FOUND,
            Json(json!({ "error": { "code": "FILE_NOT_FOUND", "message": error } })),
        )),
        Err(error) if error.contains("traversal rejected") => Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({ "error": { "code": "PROJECT_PATH_INVALID", "message": error } })),
        )),
        Err(error) => Err(internal_envelope(&error)),
    }
}

/// `PUT /api/v1/projects/{projectId}/files/{path}` — save with `If-Match`.
pub async fn save_file(
    State(state): State<AppState>,
    axum::extract::Query(workspace): axum::extract::Query<WorkspaceQuery>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    RoutePath((project_id, relative)): RoutePath<(uuid::Uuid, String)>,
    headers: axum::http::HeaderMap,
    body: Bytes,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ProjectFileWrite)
        .in_project(project_id)
        .resource(format!("project/{project_id}/files/{relative}"))
        .check()?;
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
    let if_match = headers
        .get("if-match")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_owned();
    if if_match.len() != 64 || !if_match.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(
                json!({ "error": { "code": "REVISION_INVALID", "message": "If-Match must be a 64-hex revision" } }),
            ),
        ));
    }
    if body.len() > 8 * 1024 * 1024 {
        return Err((
            StatusCode::PAYLOAD_TOO_LARGE,
            Json(json!({ "error": { "code": "FILE_TOO_LARGE", "message": "max 8 MiB per file" } })),
        ));
    }
    let view = workspace_view(project(&project_id, &state)?, &state, &workspace)?;
    let Some(manager) = &state.projects.manager else {
        return Err(internal_envelope("project service unavailable"));
    };
    let response = match manager.file_save(&view, &relative, &body, &if_match) {
        Ok(revision) => StoredResponse {
            status: StatusCode::OK,
            body: json!({ "path": relative, "revision": revision }),
            operation_id: None,
        },
        Err(crate::project::FileSaveError::Conflict {
            current_revision,
            current_content,
        }) => {
            let current_content = String::from_utf8(current_content).unwrap_or_default();
            StoredResponse {
                status: StatusCode::CONFLICT,
                body: json!({
                    "error": {
                        "code": "FILE_CONFLICT",
                        "base_revision": if_match,
                        "current_revision": current_revision,
                        "current_content": current_content,
                    }
                }),
                operation_id: None,
            }
        }
        Err(crate::project::FileSaveError::Failure(e)) if e.starts_with("FILE_NOT_FOUND:") => {
            StoredResponse {
                status: StatusCode::NOT_FOUND,
                body: json!({ "error": { "code": "FILE_NOT_FOUND", "message": e } }),
                operation_id: None,
            }
        }
        Err(crate::project::FileSaveError::Failure(e))
            if e.contains("escapes project root") || e.contains("traversal rejected") =>
        {
            StoredResponse {
                status: StatusCode::UNPROCESSABLE_ENTITY,
                body: json!({ "error": { "code": "PROJECT_PATH_INVALID", "message": e } }),
                operation_id: None,
            }
        }
        Err(crate::project::FileSaveError::Failure(e)) => {
            let (status, Json(body)) = internal_envelope(&e);
            StoredResponse {
                status,
                body,
                operation_id: None,
            }
        }
    };
    let outcome = state
        .idempotency
        .execute(&mut database.lock(), &idempotency, |_transaction| {
            Ok(response)
        })
        .map_err(|error| error.envelope())?;
    if outcome.response.status.is_success() {
        Ok(json_response(&outcome))
    } else {
        Err(json_response(&outcome))
    }
}

/// Proxy authenticated project previews only to registered ports and inject strong CSP for HTML.
pub async fn preview_asset(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    RoutePath((project_id, port, path)): RoutePath<(uuid::Uuid, u16, String)>,
) -> Response {
    let fail = |status: StatusCode, code: &str, message: &str| -> Response {
        (
            status,
            Json(json!({ "error": { "code": code, "message": message } })),
        )
            .into_response()
    };
    if let Err((status, Json(body))) = state
        .require(&principal, Capability::ProjectPreview)
        .in_project(project_id)
        .resource(format!("project/{project_id}/preview/{port}"))
        .check()
    {
        return (status, Json(body)).into_response();
    }
    let Some(manager) = &state.projects.manager else {
        return fail(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL_ERROR",
            "project service unavailable",
        );
    };
    if port == 0 {
        return fail(StatusCode::BAD_REQUEST, "PORT_INVALID", "invalid port");
    }
    // Runtime-owned loopback services are never previews, whatever the registry holds.
    if spark_core::is_runtime_owned_port(port)
        || !manager.preview_port_registered(&project_id, port)
    {
        return fail(
            StatusCode::NOT_FOUND,
            "PREVIEW_PORT_NOT_REGISTERED",
            "port not registered for preview",
        );
    }

    let Some(url) = preview_upstream_url(port, &path) else {
        return fail(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL_ERROR",
            "upstream address build failed",
        );
    };
    let client = match reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(2))
        .timeout(std::time::Duration::from_secs(30))
        .build()
    {
        Ok(client) => client,
        Err(_) => {
            return fail(
                StatusCode::INTERNAL_SERVER_ERROR,
                "INTERNAL_ERROR",
                "client build failed",
            );
        }
    };
    match client.get(url).send().await {
        Ok(mut resp) => {
            let status = resp.status();
            let content_type = resp
                .headers()
                .get("content-type")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("application/octet-stream")
                .to_owned();
            const MAX_PREVIEW_BYTES: usize = 64 * 1024 * 1024;
            let too_large = || {
                fail(
                    StatusCode::PAYLOAD_TOO_LARGE,
                    "PREVIEW_BODY_TOO_LARGE",
                    "preview exceeds the 64 MiB limit",
                )
            };
            if resp
                .content_length()
                .is_some_and(|size| size > MAX_PREVIEW_BYTES as u64)
            {
                return too_large();
            }
            let mut bytes = Vec::new();
            loop {
                match resp.chunk().await {
                    Ok(Some(chunk)) => {
                        if chunk.len() > MAX_PREVIEW_BYTES.saturating_sub(bytes.len()) {
                            return too_large();
                        }
                        bytes.extend_from_slice(&chunk);
                    }
                    Ok(None) => break,
                    Err(_) => {
                        return fail(
                            StatusCode::BAD_GATEWAY,
                            "PREVIEW_UPSTREAM_FAILED",
                            "upstream read failed",
                        );
                    }
                }
            }
            let mut builder = Response::builder()
                .status(status)
                // Set nosniff on every preview response so content-type spoofing cannot bypass the HTML CSP.
                .header("x-content-type-options", "nosniff")
                .header("content-type", content_type.clone());
            // §42.10: inject a strong CSP for content this runtime controls.
            if content_type.starts_with("text/html") {
                builder = builder.header(
                    "content-security-policy",
                    "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
                );
            }
            match builder.body(axum::body::Body::from(bytes)) {
                Ok(response) => response,
                Err(_) => fail(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "INTERNAL_ERROR",
                    "response build failed",
                ),
            }
        }
        Err(e) => fail(
            StatusCode::BAD_GATEWAY,
            "PREVIEW_UPSTREAM_FAILED",
            &format!("upstream unreachable: {e}"),
        ),
    }
}

/// Build the loopback upstream address from path segments, so the client's path is percent-encoded and can never carry a query or fragment of its own.
fn preview_upstream_url(port: u16, path: &str) -> Option<reqwest::Url> {
    let mut url = reqwest::Url::parse("http://127.0.0.1/").ok()?;
    url.set_port(Some(port)).ok()?;
    url.path_segments_mut()
        .ok()?
        .clear()
        .extend(path.split('/'));
    Some(url)
}

#[derive(Default, serde::Deserialize)]
pub struct WorkspaceQuery {
    workspace: Option<String>,
}
fn workspace_view(
    view: crate::project::ProjectView,
    state: &AppState,
    query: &WorkspaceQuery,
) -> Result<crate::project::ProjectView, (StatusCode, Json<Value>)> {
    match query.workspace.as_deref() {
        None | Some("project") => Ok(view),
        Some("development") => state.projects.manager.as_ref().ok_or_else(|| internal_envelope("Project service unavailable"))?
            .development_workspace(&view).map_err(|_| (StatusCode::NOT_FOUND, Json(json!({"error":{"code":"DEVELOPMENT_WORKSPACE_NOT_FOUND","message":"Open a development session to prepare this workspace."}})))),
        Some(_) => Err((StatusCode::BAD_REQUEST, Json(json!({"error":{"code":"WORKSPACE_INVALID","message":"Unknown workspace."}})))),
    }
}

#[cfg(test)]
mod tests {
    use super::preview_upstream_url;

    /// A client path is only ever a path upstream: query, fragment, spaces and encoded separators reach the preview server encoded, and the host and port never move.
    #[test]
    fn a_preview_path_reaches_upstream_as_an_encoded_path_with_no_query() {
        let url = preview_upstream_url(3000, "docs/a b?x=1#frag/%2F.html").unwrap();
        assert_eq!(
            url.as_str(),
            "http://127.0.0.1:3000/docs/a%20b%3Fx=1%23frag/%252F.html"
        );
        assert_eq!(url.query(), None);
        assert_eq!(url.fragment(), None);
        assert_eq!(url.host_str(), Some("127.0.0.1"));
        assert_eq!(url.port(), Some(3000));
        assert_eq!(
            preview_upstream_url(3000, "").unwrap().as_str(),
            "http://127.0.0.1:3000/"
        );
        assert_eq!(
            preview_upstream_url(3000, "a/b/").unwrap().as_str(),
            "http://127.0.0.1:3000/a/b/"
        );
        assert_eq!(
            preview_upstream_url(3000, "@evil.example/x")
                .unwrap()
                .host_str(),
            Some("127.0.0.1")
        );
    }
}
