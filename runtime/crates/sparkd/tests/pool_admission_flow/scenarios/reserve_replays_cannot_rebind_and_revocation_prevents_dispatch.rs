#[tokio::test]
async fn reserve_replays_cannot_rebind_and_revocation_prevents_dispatch() {
    let f = fixture().await;
    let g = configure(&f, &f.router).await;
    let value = reservation(&f, &g, &chat(false));
    let p = format!("{ROOT}/reservations");
    let key = Uuid::new_v4();
    let (s, a) = send(&f, &f.router, "POST", &p, Some(&value), Some(key), false).await;
    assert_eq!(s, StatusCode::CREATED);
    let (_, b) = send(&f, &f.router, "POST", &p, Some(&value), Some(key), false).await;
    assert_eq!(a, b);
    let mut changed = value.clone();
    changed["request_sha256"] = json!("f".repeat(64));
    let (s, v) = post(&f, &f.router, &p, &changed, false).await;
    assert_eq!(s, StatusCode::CONFLICT);
    assert_eq!(v["error"]["code"], "POOL_ATTEMPT_REUSED");
    let revoke = format!(
        "{ROOT}/router-grants/{}/revoke",
        g["grant_id"].as_str().unwrap()
    );
    assert_eq!(
        post(&f, &f.owner, &revoke, &json!({}), true).await.0,
        StatusCode::OK
    );
    let (_, v) = send(&f, &f.router, "GET", &path(&a, ""), None, None, false).await;
    assert_eq!(v["state"], "cancelled");
    assert_eq!(
        post(&f, &f.router, &path(&a, "/execute"), &chat(false), false)
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    close(f).await;
}
