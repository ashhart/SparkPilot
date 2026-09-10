#[tokio::test]
async fn execute_connection_failure_returns_502_and_retains_quarantine() {
    use sparkd::engine::EngineBackend;
    let f = fixture().await;
    let g = configure(&f, &f.router).await;
    let body = chat(false);
    let r = reserve(&f, &f.router, &reservation(&f, &g, &body)).await;
    f.backend
        .reconcile_instance(
            Uuid::parse_str(r["engine_instance_id"].as_str().unwrap()).unwrap(),
            None,
        )
        .await
        .unwrap();
    let (s, v) = post(&f, &f.router, &path(&r, "/execute"), &body, false).await;
    assert_eq!(s, StatusCode::BAD_GATEWAY, "{v}");
    assert_eq!(v["error"]["code"], "POOL_UPSTREAM_INCOMPLETE");
    tokio::time::sleep(Duration::from_millis(25)).await;
    let (_, v) = send(&f, &f.router, "GET", &path(&r, ""), None, None, false).await;
    assert_eq!(v["state"], "outcome_unknown");
    assert_eq!(v["capacity_released"], false);
    assert!(
        f.state
            .engine
            .manager
            .as_ref()
            .unwrap()
            .begin_request()
            .is_err()
    );
    close(f).await;
}
