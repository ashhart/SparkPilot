#[tokio::test]
async fn a_joined_guest_waits_for_the_owner_to_confirm() {
    let node = node();
    let (_, body) = create_invitation(&node).await;
    let payload: InvitationPayload =
        serde_json::from_value(body["invitation"].clone()).expect("payload");
    let guest = guest_keys();
    let (status, granted) = claim(&node, &payload, &guest).await;
    assert_eq!(status, StatusCode::CREATED, "{granted}");
    assert_eq!(granted["device"]["role"], "guest");

    // The device row keeps the lowest stored role; the grant is what makes it a guest.
    {
        let connection = node.state.database.as_ref().expect("db").lock();
        let stored = sparkd::store::device_role(&connection, &guest.device_id)
            .expect("role")
            .expect("row");
        assert_eq!(stored, "observer", "the stored role is the floor, not the grant");
        let grant = sparkd::guest::grant_for_device(&connection, &guest.device_id)
            .expect("read")
            .expect("grant");
        assert_eq!(grant.policy.state, sparkd::guest::GrantState::Pending);
        assert!(grant.joined_at.is_some());
    }

    let chat = serde_json::to_vec(&json!({
        "model": "qwen3-8b",
        "messages": [{ "role": "user", "content": "hello" }]
    }))
    .expect("body");
    let (status, refused) = run(
        &node,
        signed(
            &guest.device,
            &guest.device_id,
            Method::POST,
            "/v1/chat/completions",
            &chat,
            &rfc3339_now(),
            &fresh_nonce(),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(error_code(&refused), "GUEST_AWAITING_OWNER");

    let confirm = serde_json::to_vec(&json!({ "state": "active" })).expect("body");
    let path = format!("/api/v1/shared-access/{}", guest.device_id);
    let (status, updated) = run(
        &node,
        with_presence(&node, Method::PATCH, &path, &confirm),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{updated}");
    assert_eq!(updated["state"], "active");
    assert!(updated["confirmed_at"].is_string());

    let (status, answer) = run(
        &node,
        signed(
            &guest.device,
            &guest.device_id,
            Method::POST,
            "/v1/chat/completions",
            &chat,
            &rfc3339_now(),
            &fresh_nonce(),
        ),
    )
    .await;
    assert_ne!(status, StatusCode::FORBIDDEN, "{answer}");
    assert!(
        !error_code(&answer).starts_with("GUEST_"),
        "a confirmed guest is past the policy: {answer}"
    );
}
