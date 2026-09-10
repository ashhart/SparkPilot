#[tokio::test]
async fn warmup_review_binds_due_profile_and_idempotent_creation() {
    let p = peer("owner");
    let body = reviewed(&p).await;
    let mut changed = body.clone();
    changed["due_at"] = json!(body["due_at"].as_i64().unwrap() + 1);
    let (status, refusal) = call(
        &p,
        "POST",
        "/api/v1/inference/warmups",
        Some(changed),
        true,
        Uuid::new_v4(),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{refusal}");
    let key = Uuid::new_v4();
    let (status, first) = call(
        &p,
        "POST",
        "/api/v1/inference/warmups",
        Some(body.clone()),
        true,
        key,
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{first}");
    let (status, replay) = call(
        &p,
        "POST",
        "/api/v1/inference/warmups",
        Some(body),
        false,
        key,
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(first, replay);
    assert_eq!(rows(&p).await.as_array().unwrap().len(), 1);
}
