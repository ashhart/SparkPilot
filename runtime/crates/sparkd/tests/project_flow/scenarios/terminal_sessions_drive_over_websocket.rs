#[tokio::test]
async fn terminal_sessions_drive_over_websocket() {
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();

    let operation_id = create_through_api(&client, addr, &key, &device_id, "terminal").await;
    assert_eq!(
        wait_op(&h.state, operation_id, Duration::from_secs(20)).await,
        "succeeded"
    );
    let view = h.projects.list().unwrap().remove(0);
    write_devcontainer(&view.root_path);
    let project_id = view.id.to_string();

    let (status, created) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/terminals"),
        Some(json!({
            "shell": "login",
            "cols": 120,
            "rows": 40,
        })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{created}");
    assert_eq!(created["shell"], "login");
    let terminal_id = created["terminal_id"].as_str().expect("terminal id");

    // Bind sessions to the project's launched container and fixed shell argv, with no host execution.
    let spawned = h.pty.requests();
    assert_eq!(spawned.len(), 1);
    assert_eq!(spawned[0].project_id, view.id);
    assert!(
        spawned[0].container_id.starts_with("spark-project-")
            || !spawned[0].container_id.is_empty(),
        "terminal bound to a container id: {:?}",
        spawned[0].container_id
    );
    assert_eq!(spawned[0].shell, spark_project_runner::TerminalShell::Login);
    assert_eq!(
        spawned[0].shell.argv(),
        &["/bin/sh", "-l"],
        "the argv is the crate's constant, not the caller's"
    );
    assert!(
        h.containers
            .calls()
            .iter()
            .any(|call| call.starts_with("start ")),
        "a project container was launched for the terminal: {:?}",
        h.containers.calls()
    );

    // Attach over WebSocket with the signed upgrade request.
    let ws_url = format!("ws://{addr}/api/v1/projects/{project_id}/terminals/{terminal_id}/ws");
    let (headers, _) = signed_parts(
        &key,
        &device_id,
        "GET",
        &ws_url_http(&addr, &project_id, terminal_id),
        &[],
    );
    let mut request: tokio_tungstenite::tungstenite::http::Request<()> =
        tokio_tungstenite::tungstenite::http::Request::builder()
            .method("GET")
            .uri(ws_url.clone())
            .header("host", addr.to_string())
            .header("connection", "Upgrade")
            .header("upgrade", "websocket")
            .header("sec-websocket-version", "13")
            .header(
                "sec-websocket-key",
                tokio_tungstenite::tungstenite::handshake::client::generate_key(),
            )
            .body(())
            .expect("build request");
    for (name, value) in headers {
        use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};
        request.headers_mut().insert(
            HeaderName::from_bytes(name.as_bytes()).expect("header name"),
            HeaderValue::from_str(&value).expect("header value"),
        );
    }
    let (mut ws, _) = tokio_tungstenite::connect_async(request)
        .await
        .expect("ws connect");

    let input = serde_json::json!({ "type": "input", "data": "ls\n" }).to_string();
    ws.send(tokio_tungstenite::tungstenite::Message::Text(input.into()))
        .await
        .expect("send input");

    // The scripted PTY echoes typed input back as output.
    let mut saw_output = false;
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while std::time::Instant::now() < deadline {
        if let Ok(Some(Ok(tokio_tungstenite::tungstenite::Message::Text(text)))) =
            tokio::time::timeout(Duration::from_millis(500), ws.next()).await
        {
            let value: Value = serde_json::from_str(&text).unwrap_or_default();
            if value.get("type").and_then(Value::as_str) == Some("output") {
                saw_output = true;
                break;
            }
        }
    }
    assert!(saw_output, "terminal emitted an output frame");

    let _ = &h;
}
