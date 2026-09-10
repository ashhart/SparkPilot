#[tokio::test]
async fn preview_proxy_serves_registered_ports_with_csp() {
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();

    let operation_id = create_through_api(&client, addr, &key, &device_id, "preview").await;
    assert_eq!(
        wait_op(&h.state, operation_id, Duration::from_secs(20)).await,
        "succeeded"
    );
    let project_id = h.projects.list().unwrap().remove(0).id;

    // A tiny upstream preview server on a loopback port.
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let app = axum::Router::new().route(
            "/index.html",
            axum::routing::get(|| async {
                axum::http::Response::builder()
                    .header("content-type", "text/html")
                    .body(axum::body::Body::from(
                        "<html><title>preview</title></html>",
                    ))
                    .unwrap()
            }),
        );
        axum::serve(listener, app).await.ok();
    });
    h.projects
        .register_preview_port(&project_id, port, "spark-project-preview");

    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        &format!("/api/v1/projects/{project_id}/preview/{port}/index.html"),
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{body}");
    // Fetch raw response headers to assert HTML CSP because signed_json only returns parsed content.
    let (headers, _bytes) = signed_parts(
        &key,
        &device_id,
        "GET",
        &format!("/api/v1/projects/{project_id}/preview/{port}/index.html"),
        &[],
    );
    let mut builder = client
        .get(format!(
            "http://{addr}/api/v1/projects/{project_id}/preview/{port}/index.html"
        ))
        .header("accept", "text/html");
    for (name, value) in headers {
        builder = builder.header(name, value);
    }
    let response = builder.send().await.expect("preview");
    assert_eq!(response.status(), reqwest::StatusCode::OK);
    let csp = response
        .headers()
        .get("content-security-policy")
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);
    assert!(
        csp.as_ref()
            .is_some_and(|c| c.contains("default-src 'self'")),
        "CSP injected: {csp:?}"
    );

    // Unregistered ports are never proxied.
    let (status, _) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        &format!("/api/v1/projects/{project_id}/preview/1/index.html"),
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::NOT_FOUND);
}
