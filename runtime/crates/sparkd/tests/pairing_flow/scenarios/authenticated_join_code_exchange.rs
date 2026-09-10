fn exchange_share() -> Vec<u8> {
    let alice = b"SparkPilot pairing v2 client";
    let bob = b"SparkPilot pairing v2 server";
    unsafe {
        let context = aws_lc_sys::SPAKE2_CTX_new(
            aws_lc_sys::spake2_role_t_spake2_role_alice,
            alice.as_ptr(),
            alice.len(),
            bob.as_ptr(),
            bob.len(),
        );
        assert!(!context.is_null());
        let mut message = vec![0; 32];
        let mut count = 0;
        let ok = aws_lc_sys::SPAKE2_generate_msg(
            context,
            message.as_mut_ptr(),
            &mut count,
            32,
            b"wrong code".as_ptr(),
            10,
        );
        aws_lc_sys::SPAKE2_CTX_free(context);
        assert_eq!(ok, 1);
        assert_eq!(count, 32);
        message
    }
}

async fn exchange_request(peer: &TestPeer, message: &[u8]) -> axum::response::Response {
    let body = serde_json::to_vec(&json!({"message": base64_encode(message)})).unwrap();
    router(peer.state.clone())
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/v1/pairing/join-codes/exchange")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap()
}

#[tokio::test]
async fn authenticated_join_code_exchange_is_bounded_without_client_confirmation() {
    let mut peer = full_peer();
    peer.state.tls_fingerprint = Some("a".repeat(64));
    let (invitation, _) = bootstrap_owner_invitation(&peer);
    let message = exchange_share();
    let response = exchange_request(&peer, &message).await;
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = to_bytes(response.into_body(), 65536).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert!(envelope["sealed_package"].is_string());
    assert!(envelope.get("invitation").is_none());
    assert!(
        !String::from_utf8(bytes.to_vec())
            .unwrap()
            .contains(&invitation.invitation_id.to_string())
    );
    let database = peer.state.database.as_ref().unwrap();
    assert_eq!(
        pairing::join_code_failures_in_window(&database.lock()).unwrap(),
        1
    );
    // A client that never confirms still spends the shared budget, even using other source IPs.
    {
        let conn = database.lock();
        for _ in 1..pairing::MAX_FAILED_JOIN_CODES {
            conn.execute(
                "INSERT INTO join_code_attempts(attempted_at) VALUES (?1)",
                [sparkd::store::now_iso8601()],
            )
            .unwrap();
        }
    }
    assert_eq!(
        exchange_request(&peer, &message).await.status(),
        StatusCode::TOO_MANY_REQUESTS
    );
    assert_eq!(
        pairing::join_code_failures_in_window(&database.lock()).unwrap(),
        60
    );
}

#[tokio::test]
async fn authenticated_join_code_exchange_honors_expiry_revocation_and_consumption() {
    for update in [
        "UPDATE pairing_invitations SET expires_at = '2000-01-01T00:00:00Z'",
        "UPDATE pairing_invitations SET revoked_at = '2000-01-01T00:00:00Z'",
        "UPDATE pairing_invitations SET consumed_at = '2000-01-01T00:00:00Z'",
    ] {
        let mut peer = full_peer();
        peer.state.tls_fingerprint = Some("a".repeat(64));
        bootstrap_owner_invitation(&peer);
        peer.state
            .database
            .as_ref()
            .unwrap()
            .lock()
            .execute(update, [])
            .unwrap();
        assert_eq!(
            exchange_request(&peer, &exchange_share()).await.status(),
            StatusCode::NOT_FOUND
        );
    }
}

#[tokio::test]
async fn authenticated_join_code_exchange_rejects_malformed_shares() {
    let mut peer = full_peer();
    peer.state.tls_fingerprint = Some("a".repeat(64));
    bootstrap_owner_invitation(&peer);
    assert_eq!(
        exchange_request(&peer, &[0; 31]).await.status(),
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        pairing::join_code_failures_in_window(&peer.state.database.as_ref().unwrap().lock())
            .unwrap(),
        0
    );
}

/// Runs against the actual Apple HTTPS client, including its self-signed TLS challenge.
#[tokio::test]
#[ignore = "requires the concurrent Swift pairingCodeHTTPSInterop test"]
async fn authenticated_join_code_https_apple_interop() {
    let directory = std::path::PathBuf::from(
        std::env::var("SPARK_PAIRING_INTEROP_DIRECTORY").expect("interop directory"),
    );
    use std::os::unix::fs::PermissionsExt;
    let _ = rustls::crypto::ring::default_provider().install_default();
    let credentials = tempfile::tempdir().unwrap();
    std::fs::set_permissions(credentials.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let tls = sparkd::tls::load_or_create(credentials.path()).unwrap();
    let mut peer = full_peer();
    peer.state.tls_fingerprint = Some(tls.fingerprint.clone());
    let (_, issuer) = bootstrap_owner_invitation(&peer);
    let invitation = pairing::issue_invitation(
        &peer.state.database.as_ref().unwrap().lock(),
        &peer.identity,
        &issuer,
        "user".into(),
        Some(300),
        None,
    )
    .unwrap();
    let mut routes = Vec::new();
    let mut handles = Vec::new();
    for correct_pin in [true, false] {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        routes.push(format!(
            "https://127.0.0.1:{}",
            listener.local_addr().unwrap().port()
        ));
        let mut state = peer.state.clone();
        if !correct_pin {
            state.tls_fingerprint = Some("a".repeat(64));
        }
        let server = axum_server::tls_rustls::from_tcp_rustls(
            listener,
            axum_server::tls_rustls::RustlsConfig::from_config(tls.rustls_config()),
        )
        .unwrap();
        handles.push(tokio::spawn(server.serve(
            router(state).into_make_service_with_connect_info::<std::net::SocketAddr>(),
        )));
    }
    let details = json!({"route": routes[0], "wrongPinRoute": routes[1], "code": invitation.join_code, "fingerprint": tls.fingerprint});
    std::fs::write(
        directory.join("https.tmp"),
        serde_json::to_vec(&details).unwrap(),
    )
    .unwrap();
    std::fs::rename(directory.join("https.tmp"), directory.join("https.json")).unwrap();
    for _ in 0..1200 {
        if directory.join("https.done").exists() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    for handle in handles {
        handle.abort();
    }
    assert!(
        directory.join("https.done").exists(),
        "Apple client did not complete"
    );
}
