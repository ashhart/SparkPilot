/// L-1: the preview path is rebuilt as encoded segments, so a query, fragment, space or encoded separator in it never changes what the upstream server sees.
#[tokio::test]
async fn preview_proxy_forwards_the_path_encoded_and_never_a_query() {
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();
    let operation_id = create_through_api(&client, addr, &key, &device_id, "preview-path").await;
    assert_eq!(
        wait_op(&h.state, operation_id, Duration::from_secs(20)).await,
        "succeeded"
    );
    let project_id = h.projects.list().unwrap().remove(0).id;

    // An upstream that records exactly the request target it was handed.
    let seen: Arc<std::sync::Mutex<Vec<String>>> = Arc::default();
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let port = listener.local_addr().unwrap().port();
    let recorder = seen.clone();
    tokio::spawn(async move {
        let app = axum::Router::new().fallback(move |request: axum::extract::Request| {
            let recorder = recorder.clone();
            async move {
                recorder.lock().unwrap().push(request.uri().to_string());
                "ok"
            }
        });
        axum::serve(listener, app).await.ok();
    });
    h.projects
        .register_preview_port(&project_id, port, "spark-project-preview");

    let path = format!(
        "/api/v1/projects/{project_id}/preview/{port}/docs/a%20b%3Fx%3D1%23frag/%252F.html"
    );
    let (headers, _) = signed_parts(&key, &device_id, "GET", &path, &[]);
    let mut builder = client.get(format!("http://{addr}{path}"));
    for (name, value) in headers {
        builder = builder.header(name, value);
    }
    let response = builder.send().await.expect("preview");
    assert_eq!(response.status(), reqwest::StatusCode::OK);
    let seen = seen.lock().unwrap().clone();
    assert_eq!(
        seen,
        vec!["/docs/a%20b%3Fx=1%23frag/%252F.html".to_owned()],
        "the upstream saw an encoded path and nothing else"
    );
    assert!(!seen[0].contains('?'), "no query reached the upstream");
}
