#[tokio::test]
async fn preview_proxy_bounds_known_and_streamed_upstream_bodies() {
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();
    let operation = create_through_api(&client, addr, &key, &device_id, "bounded-preview").await;
    assert_eq!(wait_op(&h.state, operation, Duration::from_secs(20)).await, "succeeded");
    let project_id = h.projects.list().unwrap().remove(0).id;
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let app = axum::Router::new().route("/{kind}", axum::routing::get(
            |axum::extract::Path(kind): axum::extract::Path<String>| async move {
                let chunk = axum::body::Bytes::from(vec![b'x'; 1024 * 1024]);
                let stream = futures::stream::iter((0..65).map(move |_| Ok::<_, std::io::Error>(chunk.clone())));
                let mut response = axum::http::Response::builder().header("content-type", "application/octet-stream");
                if kind == "known" {
                    response = response.header("content-length", 65 * 1024 * 1024);
                }
                response.body(axum::body::Body::from_stream(stream)).unwrap()
            }
        ));
        axum::serve(listener, app).await.unwrap();
    });
    h.projects.register_preview_port(&project_id, port, "spark-project-bounded-preview");
    for kind in ["known", "streamed"] {
        let (status, body) = signed_json(&client, addr, &key, &device_id, "GET",
            &format!("/api/v1/projects/{project_id}/preview/{port}/{kind}"), None).await;
        assert_eq!(status, reqwest::StatusCode::PAYLOAD_TOO_LARGE, "{kind}: {body}");
        assert_eq!(body["error"]["code"], "PREVIEW_BODY_TOO_LARGE");
    }
    server.abort();
}
