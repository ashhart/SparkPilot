use super::*;

#[tokio::test]
async fn the_real_transport_uses_the_supplied_address_and_keeps_the_hostname() {
    use axum::{Router, routing::get};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        axum::serve(
            listener,
            Router::new().route(
                "/",
                get(|headers: axum::http::HeaderMap| async move {
                    headers["host"].to_str().unwrap().to_owned()
                }),
            ),
        )
        .await
        .unwrap();
    });
    let request = TransportRequest {
        // A test-only destination bypasses Guard so the HTTP adapter can be exercised on loopback.
        url: format!("http://transport-pin.invalid:{port}/"),
        accept: "text/plain",
        secret_header: None,
        max_bytes: 1024,
        timeout_seconds: 2,
        addresses: vec!["127.0.0.1".parse().unwrap()],
    };
    let response = HttpTransport::new().unwrap().get(&request).await.unwrap();
    assert_eq!(response.status, 200);
    assert_eq!(response.body, format!("transport-pin.invalid:{port}"));
    let unpinned = TransportRequest {
        addresses: vec![],
        ..request
    };
    assert_eq!(
        HttpTransport::new()
            .unwrap()
            .get(&unpinned)
            .await
            .unwrap_err(),
        "unpinned public destination"
    );
    server.abort();
}
