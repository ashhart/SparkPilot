#[tokio::test]
async fn losing_an_adoption_claim_is_not_proof_an_unknown_engine_stopped() {
    let mut f = fixture().await;
    let g = configure(&f, &f.router).await;
    let r = reserve(&f, &f.router, &reservation(&f, &g, &chat(false))).await;
    {
        let conn = f.state.database.as_ref().unwrap().lock();
        conn.execute("UPDATE inference_reservations SET state='accepted'", [])
            .unwrap();
        conn.execute(
            "UPDATE inference_instances SET metadata_json=?1,container_id=?2",
            rusqlite::params![
                r#"{"ownership_origin":"external_adoption"}"#,
                "f".repeat(64)
            ],
        )
        .unwrap();
    }
    f.state.pools = Arc::new(PoolService::default());
    f.state.pools.prepare(&f.state).unwrap();
    assert!(restarted_engine(&f).reconcile_startup().await.is_ok());
    let (_, v) = send(&f, &f.router, "GET", &path(&r, ""), None, None, false).await;
    assert_eq!(v["state"], "outcome_unknown");
    assert_eq!(v["capacity_released"], false);
    assert!(!f.backend.stop_started());
    close(f).await;
}
