use super::*;
use axum::routing::post;
use axum::{Router, extract::DefaultBodyLimit};
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct DevelopmentLaunch {
    pub harness: Harness,
    pub model_id: String,
    pub cluster_id: Option<uuid::Uuid>,
    pub workspace_session_id: uuid::Uuid,
    #[serde(default)]
    pub thinking_token_budget: Option<u32>,
}

#[derive(Debug, Clone, Copy, Deserialize, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Harness {
    OhMyPi,
    OpenCode,
    Pi,
    ClaudeCode,
    Codex,
}

pub(super) async fn validate_selection(
    state: &AppState,
    principal: &Principal,
    launch: &DevelopmentLaunch,
) -> Result<u64, String> {
    if launch
        .thinking_token_budget
        .is_some_and(|budget| budget > 8192)
    {
        return Err("Thinking budget must be between 0 and 8192 tokens.".into());
    }
    if launch.model_id.is_empty()
        || launch.model_id.len() > 512
        || launch.model_id.chars().any(char::is_control)
    {
        return Err("Choose a running Spark model.".into());
    }
    let active =
        crate::engine_api::active_inference(State(state.clone()), Extension(principal.clone()))
            .await
            .map_err(|(_, body)| body.to_string())?
            .0;
    if active.get("model_id").and_then(Value::as_str) != Some(&launch.model_id)
        || active
            .get("cluster_id")
            .and_then(Value::as_str)
            .map(str::to_owned)
            != launch.cluster_id.map(|id| id.to_string())
    {
        return Err(
            "The selected model or cluster has changed; choose a running model and try again."
                .into(),
        );
    }
    Ok(active
        .get("context_length")
        .and_then(Value::as_u64)
        .unwrap_or(32768))
}

pub(super) async fn prepare(
    state: &AppState,
    principal: &Principal,
    project: &crate::project::ProjectView,
    terminal_id: uuid::Uuid,
    launch: DevelopmentLaunch,
) -> Result<spark_project_runner::RunningContainer, String> {
    let context_length = validate_selection(state, principal, &launch).await?;
    let manager = state
        .projects
        .manager
        .clone()
        .ok_or("Project service unavailable")?;
    let project_copy = project.clone();
    let container =
        tokio::task::spawn_blocking(move || manager.ensure_development_workspace(&project_copy))
            .await
            .map_err(|e| e.to_string())??;
    let root = std::path::PathBuf::from(&container.worktree_path);
    // A cached pin lets the launcher skip its download; without one it downloads as before.
    let data_dir = state.config.data_dir.clone();
    let seed_root = root.clone();
    match tokio::task::spawn_blocking(move || {
        super::omp_cache::seed_workspace(&data_dir, &seed_root)
    })
    .await
    {
        Ok(Ok(_)) => {}
        Ok(Err(error)) => tracing::warn!(%error, "Oh My Pi seed skipped"),
        Err(error) => tracing::warn!(%error, "Oh My Pi seed task failed"),
    }
    let socket_name = format!(".g-{}", &terminal_id.simple().to_string()[..16]);
    // Bind only under the service-owned checkout, never a client-provided path.
    let bound = crate::beneath::bind_unix_listener_beneath(&root, &socket_name)
        .map_err(|e| e.to_string())?;
    let files = GatewayFiles {
        root: root.clone(),
        socket: socket_name.clone(),
        terminal_id,
    };
    let listener = tokio::net::UnixListener::from_std(bound).map_err(|e| e.to_string())?;
    let config = json!({
        "harness": launch.harness, "model_id": launch.model_id,
        "context_length": context_length, "socket": socket_name,
        "workspace_session_id": launch.workspace_session_id,
        "native_codex_cache": matches!(launch.harness, Harness::Codex),
    });
    crate::beneath::write_beneath(
        &root,
        &format!(".spark-session-{terminal_id}.json"),
        config.to_string().as_bytes(),
    )
    .map_err(|e| e.to_string())?;
    crate::beneath::write_beneath(
        &root,
        ".spark-pilot-launch.cjs",
        include_bytes!("development-launch.cjs"),
    )
    .map_err(|e| e.to_string())?;
    crate::beneath::write_beneath(
        &root,
        ".spark-pilot-tools.cjs",
        include_bytes!("development-tools.cjs"),
    )
    .map_err(|e| e.to_string())?;
    if let Some((manifest, lock)) = launch.harness.npm_lock() {
        for (name, contents) in [("package.json", manifest), ("package-lock.json", lock)] {
            crate::beneath::write_beneath(
                &root,
                &format!(".spark-{terminal_id}-{name}"),
                contents.as_bytes(),
            )
            .map_err(|e| e.to_string())?;
        }
    }
    let authorization = TerminalAuthorization::capture(state, principal, project.id)
        .ok_or("Development permission changed")?;
    let gateway = Gateway {
        state: state.clone(),
        principal: principal.clone(),
        launch,
        terminal_id,
        project_id: project.id,
        workspace_root: root,
        authorization,
    };
    let router = Router::new()
        .route("/v1/chat/completions", post(completions))
        .route("/v1/responses", post(responses))
        .route("/spark/codex/prepare", post(prepare_codex))
        .route("/v1/messages", post(messages))
        .route("/v1/messages/count_tokens", post(count_tokens))
        .layer(DefaultBodyLimit::max(16 * 1024 * 1024))
        .with_state(gateway.clone());
    tokio::spawn(async move {
        let _files = files;
        let lifetime = async {
            loop {
                let allocated = gateway.authorization.is_current(&gateway.state)
                    && gateway
                        .state
                        .projects
                        .manager
                        .as_ref()
                        .is_some_and(|manager| {
                            matches!(
                                manager.terminal_state(&gateway.project_id, &gateway.terminal_id),
                                Some("starting" | "running")
                            )
                        });
                if !allocated {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        };
        tokio::select! { _ = axum::serve(listener, router) => {}, _ = lifetime => {} }
    });
    Ok(container)
}

/// Remove only this process's transport/config files, including failures part-way through preparation.
struct GatewayFiles {
    root: std::path::PathBuf,
    socket: String,
    terminal_id: uuid::Uuid,
}
impl Drop for GatewayFiles {
    fn drop(&mut self) {
        for name in [
            self.socket.clone(),
            format!(".spark-session-{}.json", self.terminal_id),
            format!(".spark-{}-package.json", self.terminal_id),
            format!(".spark-{}-package-lock.json", self.terminal_id),
        ] {
            let _ = crate::beneath::remove_file_beneath(&self.root, &name);
        }
    }
}

#[derive(Clone)]
struct Gateway {
    state: AppState,
    principal: Principal,
    launch: DevelopmentLaunch,
    terminal_id: uuid::Uuid,
    project_id: uuid::Uuid,
    workspace_root: std::path::PathBuf,
    authorization: TerminalAuthorization,
}
impl Gateway {
    fn is_current(&self) -> bool {
        self.authorization.is_current(&self.state)
            && self.state.projects.manager.as_ref().is_some_and(|manager| {
                manager
                    .terminal(&self.project_id, &self.terminal_id)
                    .is_ok()
            })
    }
    fn with_thinking_budget(&self, body: Bytes) -> Bytes {
        let Some(budget) = self.launch.thinking_token_budget else {
            return body;
        };
        let Ok(mut value) = serde_json::from_slice::<Value>(&body) else {
            return body;
        };
        value["thinking_token_budget"] = budget.into();
        serde_json::to_vec(&value).map(Bytes::from).unwrap_or(body)
    }
    async fn validate(&self, body: &Bytes) -> Result<(), StatusCode> {
        if !self.is_current() {
            return Err(StatusCode::FORBIDDEN);
        }
        let value: Value = serde_json::from_slice(body).map_err(|_| StatusCode::BAD_REQUEST)?;
        if value.get("model").and_then(Value::as_str) != Some(&self.launch.model_id) {
            return Err(StatusCode::FORBIDDEN);
        }
        validate_selection(&self.state, &self.principal, &self.launch)
            .await
            .map_err(|_| StatusCode::CONFLICT)?;
        Ok(())
    }
}
async fn completions(State(gateway): State<Gateway>, body: Bytes) -> Response {
    if let Err(status) = gateway.validate(&body).await {
        return status.into_response();
    }
    let body = gateway.with_thinking_budget(body);
    crate::engine_api::chat_completions(State(gateway.state), Extension(gateway.principal), body)
        .await
        .into_response()
}
async fn responses(State(gateway): State<Gateway>, body: Bytes) -> Response {
    if let Err(status) = gateway.validate(&body).await {
        return status.into_response();
    }
    crate::engine_api::openai_responses(State(gateway.state), Extension(gateway.principal), body)
        .await
        .into_response()
}

async fn messages(State(gateway): State<Gateway>, body: Bytes) -> Response {
    if let Err(status) = gateway.validate(&body).await {
        return status.into_response();
    }
    crate::engine_api::anthropic_messages(
        State(gateway.state),
        Extension(gateway.principal),
        body,
        false,
    )
    .await
    .into_response()
}
async fn count_tokens(State(gateway): State<Gateway>, body: Bytes) -> Response {
    if let Err(status) = gateway.validate(&body).await {
        return status.into_response();
    }
    crate::engine_api::anthropic_messages(
        State(gateway.state),
        Extension(gateway.principal),
        body,
        true,
    )
    .await
    .into_response()
}

/// Update hints for the released OMP cache layout; never execute workspace binaries to ask their version.
pub(super) fn harness_updates(
    state: &AppState,
    project: &crate::project::ProjectView,
) -> Vec<Value> {
    let Some(workspace) = state
        .projects
        .manager
        .as_ref()
        .and_then(|manager| manager.development_workspace(project).ok())
    else {
        return Vec::new();
    };
    let prepared = |version: &str| {
        crate::beneath::metadata_beneath(
            &workspace.root_path,
            &format!(".spark-home/tools/omp-{version}"),
        )
        .is_ok_and(|metadata| metadata.is_file() && metadata.len() > 0)
    };
    // Existing signed releases prepared 18.1.11; fresh workspaces use this release's hash-pinned 18.1.12.
    if !prepared("18.1.12") && prepared("18.1.11") {
        vec![
            json!({"harness":"oh_my_pi", "installed_version":"18.1.11", "available_version":"18.1.12"}),
        ]
    } else {
        Vec::new()
    }
}

impl Harness {
    fn npm_lock(self) -> Option<(&'static str, &'static str)> {
        match self {
            Self::OhMyPi => None,
            Self::Pi => Some((
                include_str!("harness-locks/pi/package.json"),
                include_str!("harness-locks/pi/package-lock.json"),
            )),
            Self::OpenCode => Some((
                include_str!("harness-locks/open_code/package.json"),
                include_str!("harness-locks/open_code/package-lock.json"),
            )),
            Self::ClaudeCode => Some((
                include_str!("harness-locks/claude_code/package.json"),
                include_str!("harness-locks/claude_code/package-lock.json"),
            )),
            Self::Codex => Some((
                include_str!("harness-locks/codex/package.json"),
                include_str!("harness-locks/codex/package-lock.json"),
            )),
        }
    }
}

/// Prepare trusted public tools after the terminal opens so slow first downloads do not time out workspace creation.
async fn prepare_codex(State(gateway): State<Gateway>) -> Response {
    if !gateway.is_current() || !matches!(gateway.launch.harness, Harness::Codex) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let data_dir = gateway.state.config.data_dir.clone();
    let workspace = gateway.workspace_root.clone();
    let result =
        tokio::task::spawn_blocking(move || super::codex_cache::prepare(&data_dir, &workspace))
            .await;
    if !gateway.is_current() {
        return StatusCode::FORBIDDEN.into_response();
    }
    match result {
        Ok(Ok(directory)) => Json(json!({"directory": directory})).into_response(),
        _ => (
            StatusCode::BAD_GATEWAY,
            "Codex preparation failed; reopen the session to retry.",
        )
            .into_response(),
    }
}
