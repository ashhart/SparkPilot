#[tokio::test]
async fn grants_bind_router_caller_deployment_actions_and_expiry() {
    let f = fixture().await;
    let g = configure(&f, &f.router).await;
    let base = reservation(&f, &g, &chat(false));
    let p = format!("{ROOT}/reservations");
    assert_eq!(
        post(&f, &f.other, &p, &base, false).await.0,
        StatusCode::FORBIDDEN
    );
    for field in ["caller_device_id", "pool_id"] {
        let mut changed = base.clone();
        changed[field] = json!(Uuid::new_v4());
        assert_eq!(
            post(&f, &f.router, &p, &changed, false).await.0,
            StatusCode::FORBIDDEN
        );
    }
    let mut changed = base.clone();
    changed["deployment_id"] = json!("0".repeat(64));
    assert!(
        post(&f, &f.router, &p, &changed, false)
            .await
            .0
            .is_client_error()
    );
    {
        let conn = f.state.database.as_ref().unwrap().lock();
        let mut stripped = g.clone();
        stripped["scope"]["actions"] = json!(["status"]);
        conn.execute(
            "UPDATE inference_router_grants SET grant_json=?1",
            [stripped.to_string()],
        )
        .unwrap();
    }
    assert_eq!(
        post(&f, &f.router, &p, &base, false).await.0,
        StatusCode::FORBIDDEN
    );
    {
        let conn = f.state.database.as_ref().unwrap().lock();
        conn.execute(
            "UPDATE inference_router_grants SET grant_json=?1",
            [g.to_string()],
        )
        .unwrap();
    }
    let mut scope = g["scope"].clone();
    scope["expires_in_seconds"] = json!(1);
    let (status, short) = post(&f, &f.owner, &format!("{ROOT}/router-grants"), &scope, true).await;
    assert_eq!(status, StatusCode::OK, "{short}");
    f.clock.advance(time::Duration::seconds(2));
    assert_eq!(
        post(
            &f,
            &f.router,
            &p,
            &reservation(&f, &short, &chat(false)),
            false
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    close(f).await;
}
