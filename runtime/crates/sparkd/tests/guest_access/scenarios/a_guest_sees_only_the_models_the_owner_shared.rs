#[tokio::test]
async fn a_guest_sees_only_the_models_the_owner_shared() {
    let mut policy = evening_policy();
    policy.allowed_models = vec!["qwen3-8b".into(), "gemma3-12b".into()];
    let household = household(&policy);
    let (status, body) = send(
        &household,
        &household.guest,
        Method::GET,
        "/v1/models",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let listed: Vec<String> = body["data"]
        .as_array()
        .expect("data")
        .iter()
        .filter_map(|entry| entry["id"].as_str().map(str::to_owned))
        .collect();
    assert_eq!(listed, vec!["qwen3-8b".to_owned(), "gemma3-12b".to_owned()]);
}
