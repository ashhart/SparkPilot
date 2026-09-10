#[tokio::test]
async fn signed_qwen_recipe_loads_and_unloads_through_the_managed_api() {
    let recipe: ModelRecipe = serde_json::from_str(include_str!(
        "../../../../../../recipes/mia-ailab-qwen3.8-flash-next-nvfp4.json"
    ))
    .unwrap();
    recipe.validate().unwrap();
    let (h, addr, key, device_id) = harness_with_recipe(120 << 30, recipe.clone()).await;
    let client = reqwest::Client::new();
    let (status, response) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(json!({
            "model_id": recipe.id(), "profile_id": "spark-256k"
        })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{response}");
    let load = response["id"].as_str().unwrap().parse().unwrap();
    let terminal = wait_terminal(&h.state, load, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");
    assert!(h.engine.begin_request().is_ok());
    h.engine.request_drain().unwrap();
    assert!(h.engine.begin_request().is_err());
    h.engine.resume_guard_drain().unwrap();
    assert!(h.engine.begin_request().is_ok());
    let (status, response) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/unload",
        Some(json!({"force": true})),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{response}");
    let unload = response["id"].as_str().unwrap().parse().unwrap();
    let terminal = wait_terminal(&h.state, unload, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");
    assert!(h.engine.begin_request().is_err());
}

#[tokio::test]
async fn an_exited_qwen_process_fails_without_waiting_thirty_minutes() {
    let recipe: ModelRecipe = serde_json::from_str(include_str!(
        "../../../../../../recipes/mia-ailab-qwen3.8-flash-next-nvfp4.json"
    ))
    .unwrap();
    let (h, addr, key, device_id) = harness_with_recipe(120 << 30, recipe.clone()).await;
    h.backend.set_readiness_blocked(true);
    let client = reqwest::Client::new();
    let (_, response) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load",
        Some(json!({"model_id":recipe.id(),"profile_id":"spark-256k"})),
    )
    .await;
    let id = response["id"].as_str().unwrap().parse().unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !h.backend.readiness_started() {
        assert!(std::time::Instant::now() < deadline);
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    h.backend.crash_current_process();
    h.backend.set_readiness_blocked(false);
    let terminal = wait_terminal(&h.state, id, Duration::from_secs(4)).await;
    assert_eq!(terminal["state"], "failed", "{terminal}");
}
