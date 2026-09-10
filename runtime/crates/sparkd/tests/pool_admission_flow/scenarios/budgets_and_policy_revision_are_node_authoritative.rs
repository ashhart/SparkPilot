#[tokio::test]
async fn budgets_and_policy_revision_are_node_authoritative() {
    let f = fixture().await;
    let mut p = policy(&f, &f.router);
    p["max_buffered_bytes"] = json!(1);
    let grant = configure_policy(&f, &f.router, p).await;
    let req = reservation(&f, &grant, &chat(false));
    let (s, v) = post(&f, &f.router, &format!("{ROOT}/reservations"), &req, false).await;
    assert_eq!(s, StatusCode::CONFLICT);
    assert_eq!(v["error"]["code"], "POOL_BUFFER_BUDGET_EXCEEDED");
    let good = configure(&f, &f.router).await;
    let base = reservation(&f, &good, &chat(false));
    for (field, value) in [
        ("context_budget", json!(1_000_000)),
        ("request_bytes", json!(1_048_577)),
        ("lease_seconds", json!(31)),
        ("required_capabilities", json!(["tools"])),
    ] {
        let mut changed = base.clone();
        changed[field] = value;
        assert!(
            post(
                &f,
                &f.router,
                &format!("{ROOT}/reservations"),
                &changed,
                false
            )
            .await
            .0
            .is_client_error()
        );
    }
    let r = reserve(&f, &f.router, &base).await;
    let mut changed = policy(&f, &f.router);
    changed["pool_id"] = good["scope"]["pool_id"].clone();
    changed["revision"] = json!(2);
    changed["paused"] = json!(true);
    let (s, preview) = post(
        &f,
        &f.owner,
        &format!("{ROOT}/pools/preview"),
        &json!({"expected_revision":1,"policy":changed}),
        false,
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{preview}");
    let (s, v) = post(
        &f,
        &f.owner,
        &format!("{ROOT}/pools/apply"),
        &json!({"preview_id":preview["preview_id"]}),
        true,
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(
        post(&f, &f.router, &path(&r, "/execute"), &chat(false), false)
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    let (_, v) = send(&f, &f.router, "GET", &path(&r, ""), None, None, false).await;
    assert_eq!(v["state"], "cancelled");
    close(f).await;
}
