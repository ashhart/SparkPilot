/// Accept administrator promotion only with proof from the enrolled presence key.
#[tokio::test]
async fn promoting_a_device_requires_the_biometric_presence_key() {
    let harness = harness();
    let owner_key = fresh_key();
    let owner = seed_device(&harness.state, &owner_key, "owner");
    let presence_key = fresh_key();
    register_presence_key(&harness.state, &owner, &presence_key);
    let target = seed_device(&harness.state, &fresh_key(), "user");

    let body = serde_json::to_vec(&serde_json::json!({ "role": "administrator" })).unwrap();
    let mut request = signed(
        &owner_key,
        &owner,
        Method::PATCH,
        &format!("/api/v1/devices/{target}"),
        &body,
        &fresh_nonce(),
    );
    add_presence_proof(&mut request, &presence_key);
    let (status, body) = send(&harness.state, request).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(role_of(&harness.state, &target), "administrator");
}
