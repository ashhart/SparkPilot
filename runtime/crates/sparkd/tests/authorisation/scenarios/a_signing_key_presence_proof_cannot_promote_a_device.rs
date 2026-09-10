/// An owner's ordinary signing key must not substitute for the enrolled presence key or change another device's role.
#[tokio::test]
async fn a_signing_key_presence_proof_cannot_promote_a_device() {
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
    // Signed with the request-signing key, not the enrolled presence key.
    add_presence_proof(&mut request, &owner_key);
    let (status, body) = send(&harness.state, request).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(role_of(&harness.state, &target), "user", "role unchanged");
}
