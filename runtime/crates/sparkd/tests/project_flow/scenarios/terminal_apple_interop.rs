/// Exercises the shipping Apple socket against the real signed runtime upgrade and TLS stack.
#[tokio::test]
#[ignore = "requires the concurrent Swift terminalSocketRuntimeInterop test"]
async fn terminal_apple_interop() {
    use std::os::unix::fs::PermissionsExt;
    let directory = std::path::PathBuf::from(
        std::env::var("SPARK_TERMINAL_INTEROP_DIRECTORY").expect("interop directory"),
    );
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();
    let operation = create_through_api(&client, addr, &key, &device_id, "apple-terminal").await;
    assert_eq!(
        wait_op(&h.state, operation, Duration::from_secs(20)).await,
        "succeeded"
    );
    let project = h.projects.list().unwrap().remove(0);
    write_devcontainer(&project.root_path);
    let project_id = project.id.to_string();
    h.pty
        .queue_output(b"\x1b[2J\x1b[HOMP startup prompt> ".to_vec());
    let (status, created) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/terminals"),
        Some(json!({"shell":"login", "cols":80, "rows":24})),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED);
    let terminal_id = created["terminal_id"].as_str().unwrap();
    let _ = rustls::crypto::ring::default_provider().install_default();
    let credentials = tempfile::tempdir().unwrap();
    std::fs::set_permissions(credentials.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let tls = sparkd::tls::load_or_create(credentials.path()).unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let route = format!(
        "https://127.0.0.1:{}",
        listener.local_addr().unwrap().port()
    );
    let headers: Vec<_> = (0..3)
        .map(|_| {
            signed_parts(
                &key,
                &device_id,
                "GET",
                &ws_url_http(&addr, &project_id, terminal_id),
                &[],
            )
            .0
            .into_iter()
            .collect::<std::collections::BTreeMap<_, _>>()
        })
        .collect();
    let server = axum_server::tls_rustls::from_tcp_rustls(
        listener,
        axum_server::tls_rustls::RustlsConfig::from_config(tls.rustls_config()),
    )
    .unwrap();
    let served = h.state.clone();
    let handle = tokio::spawn(
        server.serve(router(served).into_make_service_with_connect_info::<SocketAddr>()),
    );
    let fixture = json!({"route":route,"pin":tls.fingerprint,"projectID":project_id,"terminalID":terminal_id,"headers":headers});
    std::fs::write(
        directory.join("terminal.tmp"),
        serde_json::to_vec(&fixture).unwrap(),
    )
    .unwrap();
    std::fs::rename(
        directory.join("terminal.tmp"),
        directory.join("terminal.json"),
    )
    .unwrap();
    for _ in 0..1200 {
        if directory.join("terminal.done").exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    handle.abort();
    assert!(
        directory.join("terminal.done").exists(),
        "Apple client did not complete"
    );
}
