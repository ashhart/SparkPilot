#[tokio::test]
async fn warmup_disabled_and_revoked_delegations_never_load() {
    let p = peer("owner");
    let row = schedule(&p).await;
    let path = format!(
        "/api/v1/inference/warmups/{}/disable",
        row["id"].as_str().unwrap()
    );
    let (status, _) = call(&p, "POST", &path, None, true, Uuid::new_v4()).await;
    assert_eq!(status, StatusCode::OK);
    schedule(&p).await;
    // Provision a second owner so the last-owner invariant remains intact.
    {
        let conn = p.state.database.as_ref().unwrap().lock();
        sparkd::store::insert_device(
            &conn,
            &Uuid::new_v4(),
            "other",
            "macos",
            &[1],
            "other-fingerprint",
            "owner",
        )
        .unwrap();
        sparkd::store::revoke_device(&conn, &p.device).unwrap();
    }
    p.clock.advance(time::Duration::minutes(10));
    sparkd::warmup::run_due(&p.state).await.unwrap();
    assert!(!p.backend.preparation_started());
    let conn = p.state.database.as_ref().unwrap().lock();
    let states = conn
        .prepare("SELECT state FROM warmup_schedules ORDER BY state")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(states, vec!["disabled", "revoked"]);
}
