/// A presence proof is single use and bound to its device.
#[tokio::test]
async fn a_presence_proof_is_single_use() {
    let harness = harness();
    let owner_key = fresh_key();
    let owner = seed_device(&harness.state, &owner_key, "owner");
    let presence_key = fresh_key();
    register_presence_key(&harness.state, &owner, &presence_key);
    let victim_key = fresh_key();
    let victim = seed_device(&harness.state, &victim_key, "user");
    let other_victim_key = fresh_key();
    let other_victim = seed_device(&harness.state, &other_victim_key, "user");

    let mut first = signed(
        &owner_key,
        &owner,
        Method::DELETE,
        &format!("/api/v1/devices/{victim}"),
        &[],
        &fresh_nonce(),
    );
    let proof = add_presence_proof(&mut first, &presence_key);

    let (status, _) = send(&harness.state, first).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "first use succeeds");

    // A spent proof cannot authorize another request with a new nonce and target.
    let mut replay = signed(
        &owner_key,
        &owner,
        Method::DELETE,
        &format!("/api/v1/devices/{other_victim}"),
        &[],
        &fresh_nonce(),
    );
    replay.headers_mut().insert(
        auth::HEADER_USER_PRESENCE,
        HeaderValue::from_str(&proof).unwrap(),
    );
    let (status, body) = send(&harness.state, replay).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["error"]["code"], "USER_PRESENCE_INVALID");
}
