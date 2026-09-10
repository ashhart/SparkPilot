#[tokio::test]
async fn pool_traffic_rejects_missing_peer_overlay_and_unsupported_options() {
    let f = fixture().await;
    let g = configure(&f, &f.router).await;
    let value = reservation(&f, &g, &chat(false));
    let p = format!("{ROOT}/reservations");
    for peer in [
        None,
        Some("100.100.0.1:4000"),
        Some("[fd7a:115c:a1e0::1]:4000"),
    ] {
        let mut r = request(
            &f,
            &f.router,
            "POST",
            &p,
            Some(&value),
            Some(Uuid::new_v4()),
            false,
        );
        r.extensions_mut().remove::<ConnectInfo<SocketAddr>>();
        if let Some(peer) = peer {
            r.extensions_mut()
                .insert(ConnectInfo(peer.parse::<SocketAddr>().unwrap()));
        }
        let (s, v) = response(&f, r).await;
        assert_eq!(s, StatusCode::FORBIDDEN, "{v}");
    }
    let mut body = chat(false);
    body["tools"] = json!([]);
    let r = reserve(&f, &f.router, &reservation(&f, &g, &body)).await;
    let (s, v) = post(&f, &f.router, &path(&r, "/execute"), &body, false).await;
    assert_eq!(s, StatusCode::CONFLICT, "{v}");
    close(f).await;
}
