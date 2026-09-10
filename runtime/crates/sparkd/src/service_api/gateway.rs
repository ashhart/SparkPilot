use super::*;

/// Whether an address is the LAN's own: loopback, RFC1918, IPv6 unique-local or link-local, never CGNAT, an overlay or the internet.
pub fn lan_scoped(address: std::net::IpAddr) -> bool {
    match address {
        std::net::IpAddr::V4(address) => address.is_loopback() || address.is_private(),
        std::net::IpAddr::V6(address) => {
            address.is_loopback() || address.is_unique_local() || address.is_unicast_link_local()
        }
    }
}

pub(super) fn sha256_hex(value: &[u8]) -> String {
    hex::encode(Sha256::digest(value))
}

pub(super) fn constant_time_equal(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.as_bytes()
        .iter()
        .zip(right.as_bytes())
        .fold(0u8, |difference, (left, right)| difference | (left ^ right))
        == 0
}

pub(super) fn set_gateway_state(
    database: &parking_lot::Mutex<rusqlite::Connection>,
    enabled: bool,
    pending_install: bool,
    token_sha256: &str,
    owner_device_id: uuid::Uuid,
    recipe_revision: &str,
) -> rusqlite::Result<()> {
    database.lock().execute(
        "INSERT INTO optional_services
            (service_id, enabled, pending_install, gateway_token_sha256, owner_device_id, recipe_revision, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
         ON CONFLICT(service_id) DO UPDATE SET
            enabled = excluded.enabled,
            pending_install = excluded.pending_install,
            gateway_token_sha256 = excluded.gateway_token_sha256,
            owner_device_id = excluded.owner_device_id,
            recipe_revision = excluded.recipe_revision,
            updated_at = excluded.updated_at",
        rusqlite::params![
            SERVICE_ID,
            enabled,
            pending_install,
            token_sha256,
            owner_device_id.to_string(),
            recipe_revision
        ],
    )?;
    Ok(())
}

pub(super) fn disable_gateway(
    database: &parking_lot::Mutex<rusqlite::Connection>,
) -> rusqlite::Result<()> {
    database.lock().execute(
        "UPDATE optional_services
            SET enabled = 0, pending_install = 0,
                updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
          WHERE service_id = ?1",
        [SERVICE_ID],
    )?;
    Ok(())
}

pub(super) fn clear_pending_install(
    database: &parking_lot::Mutex<rusqlite::Connection>,
) -> rusqlite::Result<()> {
    database.lock().execute(
        "UPDATE optional_services
            SET pending_install = 0,
                updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
          WHERE service_id = ?1",
        [SERVICE_ID],
    )?;
    Ok(())
}

pub(super) async fn require_gateway_token(
    State(state): State<AppState>,
    mut request: Request,
    next: Next,
) -> Response {
    if verified_open_webui_recipe(&state).is_err() {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    let supplied = request
        .headers()
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| (32..=256).contains(&value.len()));
    let Some(supplied) = supplied else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let Some(database) = &state.database else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    let stored = database.lock().query_row(
        "SELECT gateway_token_sha256, owner_device_id
           FROM optional_services
          WHERE service_id = ?1 AND enabled = 1",
        [SERVICE_ID],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
    );
    let Ok((expected_hash, owner_device_id)) = stored else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    if !constant_time_equal(&expected_hash, &sha256_hex(supplied.as_bytes())) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Ok(device_id) = uuid::Uuid::parse_str(&owner_device_id) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    request.extensions_mut().insert(Principal {
        device_id,
        role: "user".to_owned(),
        access_authentication: crate::auth::AccessAuthentication::OptionalServiceToken,
        user_presence: None,
    });
    next.run(request).await
}

/// Expose only loopback bearer-authenticated inference to Open WebUI, with no management routes.
pub fn inference_gateway_router(state: AppState) -> Router {
    Router::new()
        .route("/v1/models", get(crate::engine_api::openai_models))
        .route(
            "/v1/chat/completions",
            post(crate::engine_api::chat_completions),
        )
        .route("/v1/responses", post(crate::engine_api::openai_responses))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            require_gateway_token,
        ))
        .with_state(state)
}

pub(super) fn hop_by_hop(name: &axum::http::HeaderName) -> bool {
    matches!(
        name.as_str(),
        "connection"
            | "keep-alive"
            | "proxy-authenticate"
            | "proxy-authorization"
            | "te"
            | "trailer"
            | "transfer-encoding"
            | "upgrade"
    )
}

pub(super) async fn bridge_open_webui_socket(
    mut browser: WebSocket,
    upstream_uri: String,
    headers: HeaderMap,
) {
    let Ok(mut request) = upstream_uri.into_client_request() else {
        return;
    };
    for (name, value) in &headers {
        if matches!(
            name.as_str(),
            "authorization"
                | "cookie"
                | "host"
                | "origin"
                | "user-agent"
                | "sec-websocket-protocol"
        ) {
            request.headers_mut().insert(name, value.clone());
        }
    }
    let Ok((upstream, _)) = tokio_tungstenite::connect_async(request).await else {
        return;
    };
    let (mut upstream_sink, mut upstream_stream) = futures::StreamExt::split(upstream);
    loop {
        tokio::select! {
            browser_message = browser.recv() => {
                let Some(Ok(message)) = browser_message else { break };
                let mapped = match message {
                    AxumMessage::Text(value) => TungsteniteMessage::Text(value.to_string().into()),
                    AxumMessage::Binary(value) => TungsteniteMessage::Binary(value),
                    AxumMessage::Ping(value) => TungsteniteMessage::Ping(value),
                    AxumMessage::Pong(value) => TungsteniteMessage::Pong(value),
                    AxumMessage::Close(_) => TungsteniteMessage::Close(None),
                };
                if futures::SinkExt::send(&mut upstream_sink, mapped).await.is_err() { break; }
            }
            upstream_message = futures::StreamExt::next(&mut upstream_stream) => {
                let Some(Ok(message)) = upstream_message else { break };
                let mapped = match message {
                    TungsteniteMessage::Text(value) => AxumMessage::Text(value.to_string().into()),
                    TungsteniteMessage::Binary(value) => AxumMessage::Binary(value),
                    TungsteniteMessage::Ping(value) => AxumMessage::Ping(value),
                    TungsteniteMessage::Pong(value) => AxumMessage::Pong(value),
                    TungsteniteMessage::Close(_) => AxumMessage::Close(None),
                    TungsteniteMessage::Frame(_) => continue,
                };
                if browser.send(mapped).await.is_err() { break; }
            }
        }
    }
}

pub(super) async fn proxy_open_webui(
    State(state): State<AppState>,
    request: Request,
) -> Result<Response, StatusCode> {
    if !state
        .optional_services_available
        .load(std::sync::atomic::Ordering::SeqCst)
        || verified_open_webui_recipe(&state).is_err()
    {
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }
    let enabled = state
        .database
        .as_ref()
        .and_then(|database| {
            database
                .lock()
                .query_row(
                    "SELECT enabled FROM optional_services WHERE service_id = ?1",
                    [SERVICE_ID],
                    |row| row.get::<_, bool>(0),
                )
                .ok()
        })
        .unwrap_or(false);
    if !enabled
        || state
            .open_webui_upstream_port
            .load(std::sync::atomic::Ordering::SeqCst)
            == 0
    {
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }
    let (mut parts, body) = request.into_parts();
    let web_socket = WebSocketUpgrade::from_request_parts(&mut parts, &())
        .await
        .ok();
    let request = Request::from_parts(parts, body);
    let path_and_query = request
        .uri()
        .path_and_query()
        .map(|value| value.as_str())
        .unwrap_or("/")
        .to_owned();
    if let Some(web_socket) = web_socket {
        let upstream = format!(
            "ws://127.0.0.1:{}{path_and_query}",
            state
                .open_webui_upstream_port
                .load(std::sync::atomic::Ordering::SeqCst)
        );
        let headers = request.headers().clone();
        return Ok(web_socket
            .on_upgrade(move |socket| bridge_open_webui_socket(socket, upstream, headers))
            .into_response());
    }
    let method = request.method().clone();
    let headers = request.headers().clone();
    let body = to_bytes(request.into_body(), OPEN_WEBUI_PROXY_BODY_LIMIT)
        .await
        .map_err(|_| StatusCode::PAYLOAD_TOO_LARGE)?;
    let client = reqwest::Client::new();
    let upstream_origin = open_webui_upstream(&state);
    let mut upstream = client.request(method, format!("{upstream_origin}{path_and_query}"));
    if let Some(host) = headers.get(axum::http::header::HOST) {
        let forwarded_proto = if state.config.tls { "https" } else { "http" };
        upstream = upstream
            .header(axum::http::header::HOST, host)
            .header("x-forwarded-host", host)
            .header("x-forwarded-proto", forwarded_proto);
    }
    for (name, value) in &headers {
        if !hop_by_hop(name)
            && !name.as_str().starts_with("x-spark-")
            && name != axum::http::header::HOST
        {
            upstream = upstream.header(name, value);
        }
    }
    let response = upstream
        .body(body)
        .send()
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;
    let status = response.status();
    let headers = response.headers().clone();
    let stream = response.bytes_stream();
    let mut result = Response::builder().status(status);
    for (name, value) in &headers {
        if !hop_by_hop(name) && name != axum::http::header::LOCATION {
            result = result.header(name, value);
        }
    }
    if let Some(location) = headers
        .get(axum::http::header::LOCATION)
        .and_then(|value| value.to_str().ok())
    {
        let location = location.strip_prefix(&upstream_origin).unwrap_or(location);
        result = result.header(axum::http::header::LOCATION, location);
    }
    result
        .body(Body::from_stream(stream))
        .map_err(|_| StatusCode::BAD_GATEWAY)
}

/// Proxy Open WebUI at its own TLS origin without path rewriting while its container stays loopback-only.
pub fn access_proxy_router(state: AppState) -> Router {
    Router::new()
        .fallback(any(proxy_open_webui))
        .with_state(state)
}

fn valid_port(port: &str) -> bool {
    !port.is_empty() && port.len() <= 5 && port.bytes().all(|byte| byte.is_ascii_digit())
}

/// Retain only LAN hosts (private/loopback IP, localhost, single label or .local); always use API port + 1.
pub(super) fn redirect_host(authority: &str) -> Option<String> {
    let forbidden = |character: char| {
        !character.is_ascii_graphic() || matches!(character, '@' | '/' | '?' | '#' | '\\' | '%')
    };
    if authority.is_empty() || authority.len() > 260 || authority.chars().any(forbidden) {
        return None;
    }
    if let Some(rest) = authority.strip_prefix('[') {
        let (literal, suffix) = rest.split_once(']')?;
        let address: std::net::Ipv6Addr = literal.parse().ok()?;
        if !(suffix.is_empty() || suffix.strip_prefix(':').is_some_and(valid_port)) {
            return None;
        }
        return lan_scoped(address.into()).then(|| format!("[{address}]"));
    }
    let host = match authority.rsplit_once(':') {
        Some((host, port)) if valid_port(port) => host,
        Some(_) => return None,
        None => authority,
    };
    if let Ok(address) = host.parse::<std::net::Ipv4Addr>() {
        return lan_scoped(address.into()).then(|| address.to_string());
    }
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    let label_valid = |label: &str| {
        !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    };
    let names_this_lan = host == "localhost" || !host.contains('.') || host.ends_with(".local");
    (!host.is_empty() && host.len() <= 253 && host.split('.').all(label_valid) && names_this_lan)
        .then_some(host)
}

pub async fn open_webui_redirect(
    State(state): State<AppState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
) -> Result<axum::response::Redirect, StatusCode> {
    if !state
        .optional_services_available
        .load(std::sync::atomic::Ordering::SeqCst)
        || verified_open_webui_recipe(&state).is_err()
    {
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }
    let port = state
        .config
        .listen
        .port()
        .checked_add(1)
        .ok_or(StatusCode::SERVICE_UNAVAILABLE)?;
    let requested = headers
        .get(axum::http::header::HOST)
        .and_then(|value| value.to_str().ok())
        .or_else(|| uri.authority().map(|authority| authority.as_str()));
    // The browser must land on the certificate identity it already accepted, so the host it used wins over the advertised name whenever it names this LAN.
    let host = requested.and_then(redirect_host).unwrap_or_else(|| {
        format!(
            "{}.local",
            crate::bonjour::instance_label(
                &state.config.node_name,
                &crate::bonjour::short_node_id(state.identity.node_id())
            )
        )
    });
    let scheme = if state.config.tls { "https" } else { "http" };
    Ok(axum::response::Redirect::temporary(&format!(
        "{scheme}://{host}:{port}/"
    )))
}

#[cfg(test)]
mod tests {
    use super::redirect_host;

    /// The redirect follows the host the browser used only when it names this LAN, so no request can steer a browser anywhere else.
    #[test]
    fn the_redirect_host_is_the_browsers_own_lan_name_or_nothing() {
        for (authority, expected) in [
            ("192.168.1.20:7443", "192.168.1.20"),
            ("10.0.0.5", "10.0.0.5"),
            ("127.0.0.1:7443", "127.0.0.1"),
            ("[fd00::1]:7443", "[fd00::1]"),
            ("[::1]", "[::1]"),
            ("[fe80::1]:7443", "[fe80::1]"),
            ("spark.local:7443", "spark.local"),
            ("Spark-One.LOCAL:7443", "spark-one.local"),
            ("spark.local.", "spark.local"),
            ("localhost:7443", "localhost"),
            ("spark", "spark"),
        ] {
            assert_eq!(
                redirect_host(authority).as_deref(),
                Some(expected),
                "{authority}"
            );
        }
        for rejected in [
            "",
            "attacker.example",
            "attacker.example:7443",
            "spark.local.attacker.example",
            "user@spark.local",
            "spark.local/evil",
            "spark.local?x=1",
            "spark.local#fragment",
            "spark.local\\evil",
            "spark.local:port",
            "spark.local:",
            "spark.local:7443:1",
            "spark .local",
            "-spark.local",
            "spark-.local",
            "a..local",
            "%73park.local",
            "203.0.113.5",
            "100.64.0.1:7443",
            "0.0.0.0",
            "[2001:db8::1]:7443",
            "fd00::1",
            "[fd00::1",
            "[fd00::1]x",
            "spark.local\r\n",
        ] {
            assert_eq!(
                redirect_host(rejected),
                None,
                "{rejected:?} must not be followed"
            );
        }
        let long = format!("{}.local", "a".repeat(64));
        assert_eq!(redirect_host(&long), None, "a label over 63 octets");
    }
}
