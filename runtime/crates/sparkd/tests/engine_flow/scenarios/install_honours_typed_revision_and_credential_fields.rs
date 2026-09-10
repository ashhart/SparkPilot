#[tokio::test]
async fn install_honours_typed_revision_and_credential_fields() {
    let (_h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let path = "/api/v1/models/example%2Fmodel-32b/install";
    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        path,
        Some(json!({ "recipe_revision": "stale-recipe" })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::CONFLICT, "{body}");
    assert_eq!(body["error"]["code"], "MODEL_RECIPE_REVISION_MISMATCH");

    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        path,
        Some(json!({ "provider_credential_id": "not-a-uuid" })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::UNPROCESSABLE_ENTITY, "{body}");
    assert_eq!(body["error"]["code"], "CREDENTIAL_INVALID");
}
