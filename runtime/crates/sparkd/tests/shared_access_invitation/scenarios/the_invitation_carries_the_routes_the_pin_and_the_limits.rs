#[tokio::test]
async fn the_invitation_carries_the_routes_the_pin_and_the_limits() {
    let node = node();
    let (status, body) = create_invitation(&node).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");

    let payload: InvitationPayload =
        serde_json::from_value(body["invitation"].clone()).expect("payload");
    assert_eq!(payload.version, 2);
    assert_eq!(payload.role, "guest");
    assert_eq!(payload.node_id, SIGNING_NODE_ID);
    assert_eq!(
        payload.node_name.as_deref(),
        Some(node.identity.public.node_name.as_str())
    );
    assert_eq!(payload.tls_fingerprint.as_deref(), Some("a".repeat(64).as_str()));
    assert!(
        payload
            .local_endpoint
            .as_deref()
            .is_some_and(|route| route.contains(".local:7443")),
        "the local route is carried: {:?}",
        payload.local_endpoint
    );
    assert_eq!(
        payload.remote_hostname, None,
        "no tailnet name is claimed while remote access is off"
    );
    let shared = payload.shared_access.as_ref().expect("limits");
    assert_eq!(shared.display_name, "Sam");
    assert_eq!(shared.allowed_models, vec!["qwen3-8b".to_owned()]);
    assert_eq!(shared.daily_token_budget, 10_000);
    assert_eq!(shared.allowed_hours.len(), 7);
    payload.verify(&node.identity).expect("the payload verifies");

    assert_eq!(body["node_name"], node.identity.public.node_name);
    assert_eq!(body["tls_fingerprint"], "a".repeat(64));
    assert!(body["authority_public_key"].is_string());

    let connection = node.state.database.as_ref().expect("db").lock();
    let grant = sparkd::guest::grant_by_invitation(&connection, &payload.invitation_id)
        .expect("read")
        .expect("grant");
    assert_eq!(grant.policy.state, sparkd::guest::GrantState::Pending);
    assert_eq!(grant.policy.display_name, "Sam");
}
