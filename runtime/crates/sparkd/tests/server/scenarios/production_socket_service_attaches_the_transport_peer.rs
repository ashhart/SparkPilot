#[tokio::test]
async fn production_socket_service_attaches_the_transport_peer() {
    use axum::extract::ConnectInfo;
    use axum::routing::get;

    async fn peer(ConnectInfo(peer): ConnectInfo<std::net::SocketAddr>) -> String {
        peer.ip().to_string()
    }

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let app = axum::Router::new().route("/peer", get(peer));
        let _ = axum::serve(listener, socket_service(app)).await;
    });
    let response = reqwest::get(format!("http://{address}/peer"))
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    assert_eq!(response, "127.0.0.1");
    server.abort();
}
