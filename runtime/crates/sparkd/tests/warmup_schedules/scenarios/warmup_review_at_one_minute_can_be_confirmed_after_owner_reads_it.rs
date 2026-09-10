#[tokio::test]
async fn warmup_review_at_one_minute_can_be_confirmed_after_owner_reads_it() {
    let p = peer("owner");
    let mut body = draft_request(&p);
    body["due_at"] = json!(p.clock.now().unix_timestamp() + 60);
    let (status, preview) = call(
        &p,
        "POST",
        "/api/v1/inference/warmups/preview",
        Some(body.clone()),
        false,
        Uuid::new_v4(),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    body["accepted_preview_digest"] = preview["review"]["preview_digest"].clone();
    p.clock.advance(time::Duration::seconds(5));
    let (status, receipt) = call(
        &p,
        "POST",
        "/api/v1/inference/warmups",
        Some(body),
        true,
        Uuid::new_v4(),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{receipt}");
}
