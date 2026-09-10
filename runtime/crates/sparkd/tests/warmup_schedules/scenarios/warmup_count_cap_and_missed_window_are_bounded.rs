#[tokio::test]
async fn warmup_count_cap_and_missed_window_are_bounded() {
    let p = peer("owner");
    for _ in 0..8 {
        schedule(&p).await;
    }
    let body = reviewed(&p).await;
    let (status, refusal) = call(
        &p,
        "POST",
        "/api/v1/inference/warmups",
        Some(body),
        true,
        Uuid::new_v4(),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(refusal["error"]["code"], "WARMUP_LIMIT_REACHED");
    p.clock.advance(time::Duration::minutes(21));
    sparkd::warmup::run_due(&p.state).await.unwrap();
    assert!(
        rows(&p)
            .await
            .as_array()
            .unwrap()
            .iter()
            .all(|row| row["state"] == "expired")
    );
    assert!(!p.backend.preparation_started());
}
