#[tokio::test]
async fn tls_server_serves_health() {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("install rustls ring provider");
    let (state, _) = test_state();
    let app = router(state);

    let certified = rcgen::generate_simple_self_signed(vec!["spark.local".to_owned()]).unwrap();
    let tls = axum_server::tls_rustls::RustlsConfig::from_pem(
        certified.cert.pem().into_bytes(),
        certified.signing_key.serialize_pem().into_bytes(),
    )
    .await
    .unwrap();

    // Bind an ephemeral async listener and serve it through the dedicated TLS acceptor.
    let tokio_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = tokio_listener.local_addr().unwrap();
    let server = axum_server::Server::<std::net::SocketAddr>::from_listener(tokio_listener)
        .acceptor(axum_server::tls_rustls::RustlsAcceptor::new(tls));
    let handle = tokio::spawn(async move {
        let _ = server.serve(app.into_make_service()).await;
    });

    let client = reqwest::Client::builder()
        .danger_accept_invalid_certs(true)
        .build()
        .unwrap();
    let url = format!("https://{addr}/api/v1/health");

    let response = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            match client.get(&url).send().await {
                Ok(r) => return r,
                Err(_) => tokio::time::sleep(std::time::Duration::from_millis(50)).await,
            }
        }
    })
    .await
    .expect("server should accept TLS within 5s");

    assert_eq!(response.status().as_u16(), 200);
    handle.abort();
}
