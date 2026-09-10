#[tokio::test]
async fn warmup_signed_owner_presence_review_and_timing_are_required() {
    let p = peer("administrator");
    let (status, body) = call(
        &p,
        "POST",
        "/api/v1/inference/warmups/preview",
        Some(draft_request(&p)),
        false,
        Uuid::new_v4(),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    let p = peer("owner");
    let body = reviewed(&p).await;
    let (status, refusal) = call(
        &p,
        "POST",
        "/api/v1/inference/warmups",
        Some(body),
        false,
        Uuid::new_v4(),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(refusal["error"]["code"], "USER_PRESENCE_REQUIRED");
    let (status, refusal) = call(
        &p,
        "POST",
        "/api/v1/inference/warmups",
        Some(draft_request(&p)),
        true,
        Uuid::new_v4(),
    )
    .await;
    assert_eq!(status, StatusCode::PRECONDITION_REQUIRED, "{refusal}");
    for due in [
        p.clock.now().unix_timestamp(),
        p.clock.now().unix_timestamp() + 8 * 86400,
        i64::MAX,
    ] {
        let mut body = draft_request(&p);
        body["due_at"] = json!(due);
        let (status, refusal) = call(
            &p,
            "POST",
            "/api/v1/inference/warmups/preview",
            Some(body),
            false,
            Uuid::new_v4(),
        )
        .await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{refusal}");
    }
    assert_eq!(rows(&p).await, json!([]));
}
