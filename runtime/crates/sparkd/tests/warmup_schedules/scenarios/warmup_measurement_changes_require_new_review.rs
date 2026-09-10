#[tokio::test]
async fn warmup_measurement_changes_require_new_review() {
    let p = peer("owner");
    schedule(&p).await;
    sparkd::guard::record_profile_peak(
        &p.state.database.as_ref().unwrap().lock(),
        MODEL,
        PROFILE,
        110_000_000_000,
        &fixture_environment(),
    )
    .unwrap();
    p.clock.advance(time::Duration::minutes(10));
    sparkd::warmup::run_due(&p.state).await.unwrap();
    let row = rows(&p).await[0].clone();
    assert_eq!(row["state"], "skipped");
    assert_eq!(row["result_code"], "WARMUP_REVIEW_CHANGED");
    assert!(!p.backend.preparation_started());
}
