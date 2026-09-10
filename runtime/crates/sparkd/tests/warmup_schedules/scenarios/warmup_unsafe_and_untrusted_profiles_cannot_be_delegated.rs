#[tokio::test]
async fn warmup_unsafe_and_untrusted_profiles_cannot_be_delegated() {
    let mut p = peer("owner");
    sparkd::guard::mark_profile_unsafe(
        &p.state.database.as_ref().unwrap().lock(),
        MODEL,
        PROFILE,
        "MEMORY_PRESSURE_CRITICAL",
    )
    .unwrap();
    let mut body = draft_request(&p);
    let (status, review) = call(
        &p,
        "POST",
        "/api/v1/inference/warmups/preview",
        Some(body.clone()),
        false,
        Uuid::new_v4(),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{review}");
    assert!(
        review["review"]["blockers"]
            .as_array()
            .unwrap()
            .iter()
            .any(|blocker| blocker["code"] == "MODEL_PROFILE_UNSAFE")
    );
    body["accepted_preview_digest"] = review["review"]["preview_digest"].clone();
    let (status, refusal) = call(
        &p,
        "POST",
        "/api/v1/inference/warmups",
        Some(body),
        true,
        Uuid::new_v4(),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{refusal}");
    assert_eq!(rows(&p).await, json!([]));
    let mut recipe = p
        .state
        .models
        .as_ref()
        .unwrap()
        .snapshot()
        .recipe(MODEL)
        .unwrap()
        .clone();
    recipe.profiles[0].max_sequences += 1;
    let mut tampered = p.state.clone();
    tampered.models = Some(Arc::new(sparkd::models::LiveModelInventory::new(Arc::new(
        sparkd::models::ModelInventory {
            recipes: vec![recipe],
            allow_unverified_import: false,
        },
    ))));
    let original = p.state.models.as_ref().unwrap();
    assert!(original.snapshot().recipe(MODEL).is_some());
    p.state = tampered;
    let q = p;
    let (status, refusal) = call(
        &q,
        "POST",
        "/api/v1/inference/warmups/preview",
        Some(draft_request(&q)),
        false,
        Uuid::new_v4(),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(refusal["error"]["code"], "MODEL_RECIPE_UNTRUSTED");
}
