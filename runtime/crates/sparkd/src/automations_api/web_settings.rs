use super::*;

/// Where the owner's web-access decision is stored, alongside the other appliance settings.
pub const WEB_ACCESS_KEY: &str = "web_access";
const WEB_SETTINGS_ROUTE: &str = "/api/v1/web/settings";
const WEB_SETTINGS_KIND: &str = "settings.web_access";

/// The stored shape. Kept separate from the runtime struct so a stored row is always readable.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct StoredWebAccess {
    pub policy: String,
    pub harness_access: bool,
    pub search_backend: String,
    pub searxng_url: Option<String>,
    pub brave_credential_id: Option<Uuid>,
    pub allow_domains: Vec<String>,
    pub deny_domains: Vec<String>,
    pub updated_at: i64,
}

impl Default for StoredWebAccess {
    fn default() -> Self {
        let settings = WebAccessSettings::default();
        Self {
            policy: settings.policy.name().to_owned(),
            harness_access: false,
            search_backend: settings.backend.name().to_owned(),
            searxng_url: settings.searxng_url,
            brave_credential_id: None,
            allow_domains: Vec::new(),
            deny_domains: Vec::new(),
            updated_at: 0,
        }
    }
}

impl StoredWebAccess {
    fn into_settings(self) -> WebAccessSettings {
        WebAccessSettings {
            policy: WebAccessPolicy::parse(&self.policy).unwrap_or_default(),
            harness_access: self.harness_access,
            backend: SearchBackend::parse(&self.search_backend).unwrap_or(SearchBackend::Disabled),
            searxng_url: self.searxng_url,
            brave_credential_id: self.brave_credential_id,
            allow_domains: self.allow_domains,
            deny_domains: self.deny_domains,
            updated_at: self.updated_at,
        }
    }

    fn from_settings(settings: &WebAccessSettings) -> Self {
        Self {
            policy: settings.policy.name().to_owned(),
            harness_access: settings.harness_access,
            search_backend: settings.backend.name().to_owned(),
            searxng_url: settings.searxng_url.clone(),
            brave_credential_id: settings.brave_credential_id,
            allow_domains: settings.allow_domains.clone(),
            deny_domains: settings.deny_domains.clone(),
            updated_at: settings.updated_at,
        }
    }
}

/// The owner's stored decision, or the closed default when nothing is stored or the row is unreadable.
pub fn load(state: &AppState) -> WebAccessSettings {
    let Some(database) = &state.database else {
        return WebAccessSettings::default();
    };
    let conn = database.lock();
    crate::appliance_api::load_web_access(&conn)
        .ok()
        .flatten()
        .unwrap_or_default()
        .into_settings()
}

/// The owner's search key, read only when the chosen backend needs one.
pub fn secret(state: &AppState, settings: &WebAccessSettings) -> Option<String> {
    let credential = settings.brave_credential_id?;
    if !settings.backend.needs_secret() {
        return None;
    }
    let database = state.database.as_ref()?;
    let path = {
        let conn = database.lock();
        let store = crate::credentials::CredentialStore::new(&state.config.data_dir);
        if store.provider(&conn, credential).ok()?? != BRAVE_PROVIDER {
            return None;
        }
        store.resolve(&conn, credential).ok()??
    };
    std::fs::read_to_string(path)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

/// Ask the helper whether this Spark's own search service is installed and answering.
fn local_search_state(state: &AppState) -> &'static str {
    let Some(client) = state.privileged.clone() else {
        return "unknown";
    };
    let response = client.call_bounded(
        spark_privd::protocol::PrivilegedOperation::SearxngService {
            request_id: Uuid::new_v4(),
            action: spark_privd::protocol::SearxngAction::Status,
        },
        std::time::Duration::from_secs(3),
    );
    match response {
        Ok(response) if response.accepted => {
            if response.details["healthy"] == json!(true) {
                "running"
            } else if response.details["installed"] == json!(true) {
                "unhealthy"
            } else {
                "not_installed"
            }
        }
        _ => "unknown",
    }
}

fn presented(settings: &WebAccessSettings, local_search_state: &str) -> Value {
    json!({
        "policy": settings.policy.name(),
        "harness_access": settings.harness_access,
        "search_backend": settings.backend.name(),
        "searxng_url": settings.searxng_url,
        "brave_credential_id": settings.brave_credential_id,
        "local_search_state": local_search_state,
        "allow_domains": settings.allow_domains,
        "deny_domains": settings.deny_domains,
        "limits": {
            "max_tool_calls": session::MAX_TOOL_CALLS,
            "max_fetch_bytes": session::MAX_FETCH_BYTES,
            "max_run_bytes": session::MAX_RUN_BYTES,
            "max_run_seconds": session::MAX_RUN_SECONDS,
            "max_request_seconds": session::MAX_REQUEST_SECONDS,
        },
        "updated_at": settings.updated_at,
    })
}

pub async fn get_web_access_settings(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, Denial> {
    state
        .require(&principal, Capability::AutomationRead)
        .resource(WEB_SETTINGS_ROUTE)
        .check()?;
    let settings = load(&state);
    let local = tokio::task::spawn_blocking({
        let state = state.clone();
        move || local_search_state(&state)
    })
    .await
    .unwrap_or("unknown");
    Ok(Json(presented(&settings, local)))
}

#[derive(Debug, Clone, Deserialize)]
pub struct WebAccessRequest {
    pub policy: String,
    #[serde(default)]
    pub harness_access: bool,
    pub search_backend: String,
    #[serde(default)]
    pub searxng_url: Option<String>,
    #[serde(default)]
    pub brave_credential_id: Option<Uuid>,
    #[serde(default)]
    pub allow_domains: Vec<String>,
    #[serde(default)]
    pub deny_domains: Vec<String>,
}

pub async fn set_web_access_settings(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<WebAccessRequest>,
) -> Result<(StatusCode, Json<Value>), Denial> {
    // Only an owner decides whether this appliance reaches the internet at all.
    if principal.role != "owner" {
        return Err(envelope(
            StatusCode::FORBIDDEN,
            "ROLE_FORBIDDEN",
            "only the owner can change what the model may reach on the internet",
        ));
    }
    let settings = WebAccessSettings {
        policy: WebAccessPolicy::parse(&request.policy).ok_or_else(|| {
            envelope(
                StatusCode::BAD_REQUEST,
                "WEB_ACCESS_POLICY_INVALID",
                "that is not a web-access policy this Spark understands",
            )
        })?,
        harness_access: request.harness_access,
        backend: SearchBackend::parse(&request.search_backend).ok_or_else(|| {
            envelope(
                StatusCode::BAD_REQUEST,
                "WEB_SEARCH_BACKEND_INVALID",
                "that is not a search service this Spark can ask",
            )
        })?,
        searxng_url: request.searxng_url.clone(),
        brave_credential_id: request.brave_credential_id,
        allow_domains: request.allow_domains.clone(),
        deny_domains: request.deny_domains.clone(),
        updated_at: state.clock.now().unix_timestamp(),
    };
    settings.validate().map_err(|code| {
        envelope(
            StatusCode::BAD_REQUEST,
            code,
            crate::web_tools::policy::explanation(code),
        )
    })?;
    if settings.policy != WebAccessPolicy::Off
        && settings.backend == SearchBackend::Brave
        && secret(&state, &settings).is_none()
    {
        return Err(envelope(
            StatusCode::BAD_REQUEST,
            "WEB_SEARCH_BACKEND_INCOMPLETE",
            "Save a Brave Search key on this Spark before choosing Brave.",
        ));
    }
    let stored = StoredWebAccess::from_settings(&settings);
    // Choosing the Spark's own search installs it in the same operation.
    let install_local = settings.policy != WebAccessPolicy::Off
        && settings.backend == SearchBackend::Searxng
        && settings.searxng_url.as_deref() == Some(crate::web_tools::backend::SEARXNG_LOCAL_URL);
    let privileged = state.privileged.clone();
    let database = state.database.clone().ok_or_else(|| {
        envelope(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL",
            "settings database is unavailable",
        )
    })?;
    let timestamp = state.clock.now_rfc3339();
    let device_id = principal.device_id;
    crate::appliance_api::enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        WEB_SETTINGS_ROUTE,
        WEB_SETTINGS_KIND,
        json!({"policy": stored.policy, "harness_access": stored.harness_access, "search_backend": stored.search_backend}),
        None,
        move |operation_id, lease| {
            let mut local = "unknown";
            if install_local {
                local = match privileged.as_ref().map(|client| {
                    client.call(spark_privd::protocol::PrivilegedOperation::SearxngService {
                        request_id: operation_id,
                        action: spark_privd::protocol::SearxngAction::Install,
                    })
                }) {
                    Some(Ok(response)) if response.accepted => "running",
                    Some(Ok(_)) => "unhealthy",
                    _ => "unknown",
                };
                if local != "running" {
                    let _ = lease.fail("WEB_SEARCH_UNAVAILABLE");
                    return;
                }
            }
            let written = {
                let conn = database.lock();
                crate::appliance_api::store_web_access(&conn, &stored, &timestamp, device_id)
            };
            match written {
                Ok(()) => {
                    lease.settle_succeeded(&presented(&settings, local));
                }
                Err(error) => {
                    tracing::error!(%error, "web access setting persistence failed");
                    lease.settle_failed("SETTINGS_PERSISTENCE_FAILED");
                }
            }
        },
    )
    .await
}
