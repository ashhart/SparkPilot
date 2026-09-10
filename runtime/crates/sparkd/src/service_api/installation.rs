use super::*;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InstallOpenWebUiRequest {
    pub(super) admin_email: Option<String>,
    pub(super) admin_name: Option<String>,
    pub(super) admin_password: Option<SecretString>,
    pub(super) accepted_recipe_revision: String,
    pub(super) port: Option<u16>,
    #[serde(default)]
    pub(super) adopt_existing: bool,
}

pub(super) fn valid_admin(email: &str, name: &str, password: &str) -> bool {
    email.len() <= 254
        && email.contains('@')
        && !email.chars().any(char::is_control)
        && (1..=120).contains(&name.len())
        && !name.chars().any(char::is_control)
        && (16..=128).contains(&password.len())
        && !password.chars().any(char::is_control)
}

pub async fn install_open_webui(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<InstallOpenWebUiRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let recipe = recipe(&state)?;
    if request.accepted_recipe_revision != recipe.metadata.revision {
        return Err(envelope(
            StatusCode::CONFLICT,
            "SERVICE_RECIPE_CHANGED",
            "review and accept the current Open WebUI recipe before installing",
        ));
    }
    let port = request
        .port
        .unwrap_or(spark_privd::protocol::default_open_webui_port());
    let adopt_existing = request.adopt_existing;
    if !spark_privd::protocol::valid_open_webui_port(port)
        || port == state.config.listen.port()
        || state.config.listen.port().checked_add(1) == Some(port)
    {
        return Err(envelope(
            StatusCode::UNPROCESSABLE_ENTITY,
            "OPEN_WEBUI_PORT_INVALID",
            "Choose a non-reserved service port between 1024 and 65535",
        ));
    }
    let admin_email = request.admin_email.unwrap_or_default();
    let admin_name = request.admin_name.unwrap_or_default();
    let admin_password = request
        .admin_password
        .unwrap_or_else(|| SecretString::new(String::new()));
    if !adopt_existing && !valid_admin(&admin_email, &admin_name, admin_password.expose_secret()) {
        return Err(envelope(
            StatusCode::UNPROCESSABLE_ENTITY,
            "OPEN_WEBUI_ADMIN_INVALID",
            "provide a valid email, display name, and unique password of at least 16 characters",
        ));
    }
    let client = privileged(&state)?;
    let mut token = [0u8; 32];
    rand::rng().fill_bytes(&mut token);
    let gateway_api_key = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(token);
    let gateway_token_sha256 = sha256_hex(gateway_api_key.as_bytes());
    let owner_device_id = principal.device_id;
    let database = state.database.clone().ok_or_else(|| {
        envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "OPTIONAL_SERVICES_UNAVAILABLE",
            "optional service state is unavailable",
        )
    })?;
    let existing_gateway_state = database
        .lock()
        .query_row(
            "SELECT enabled, pending_install FROM optional_services WHERE service_id = ?1",
            [SERVICE_ID],
            |row| Ok((row.get::<_, bool>(0)?, row.get::<_, bool>(1)?)),
        )
        .unwrap_or((false, false));
    let already_configured = existing_gateway_state.0 || existing_gateway_state.1;
    let image_digest = recipe.container.image;
    let revision = recipe.metadata.revision;
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/services/open-webui/install",
        "service.open_webui.install",
        json!({
            "service_id": SERVICE_ID,
            "recipe_revision": revision,
            "protected_input_supplied": !adopt_existing,
            "port": port,
            "adopt_existing": adopt_existing,
        }),
        None,
        move |operation_id, lease| {
            if already_configured {
                lease.settle_failed("OPEN_WEBUI_ALREADY_INSTALLED");
                return;
            }
            if let Err(error) = set_gateway_state(
                database.as_ref(),
                false,
                true,
                &gateway_token_sha256,
                owner_device_id,
                &revision,
            ) {
                tracing::error!(%error, "could not persist pending Open WebUI gateway state");
                lease.settle_failed("OPEN_WEBUI_GATEWAY_STATE_FAILED");
                return;
            }
            let result = client.call(PrivilegedOperation::InstallOpenWebUi {
                request_id: operation_id,
                image_digest,
                admin_email,
                admin_name,
                admin_password,
                gateway_api_key: SecretString::new(gateway_api_key),
                port,
                adopt_existing,
            });
            match result {
                Ok(response) if response.accepted => {
                    if let Err(error) = set_gateway_state(
                        database.as_ref(),
                        true,
                        false,
                        &gateway_token_sha256,
                        owner_device_id,
                        &revision,
                    ) {
                        tracing::error!(%error, "could not persist Open WebUI gateway state");
                        lease.settle_failed("OPEN_WEBUI_GATEWAY_STATE_FAILED");
                    } else if let Err(error) = lease.succeed(&json!({
                        "service_id": SERVICE_ID,
                        "recipe_revision": revision,
                        "state": "healthy",
                    })) {
                        tracing::error!(%error, "could not persist Open WebUI install success");
                    }
                }
                Ok(response) => {
                    let _ = clear_pending_install(database.as_ref());
                    lease.settle_failed(&response.code);
                }
                Err(error) => {
                    tracing::error!(%error, "Open WebUI install boundary failed");
                    let _ = clear_pending_install(database.as_ref());
                    lease.settle_failed("OPEN_WEBUI_INSTALL_FAILED");
                }
            }
        },
    )
    .await
}
