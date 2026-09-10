#[tokio::test]
async fn an_altered_invitation_is_refused_because_it_is_signed() {
    let node = node();
    let (_, body) = create_invitation(&node).await;
    let payload: InvitationPayload =
        serde_json::from_value(body["invitation"].clone()).expect("payload");
    payload.verify(&node.identity).expect("the issued payload verifies");

    // Every field a middle party would want to change is inside the signature.
    for alter in [
        |payload: &mut InvitationPayload| {
            payload
                .shared_access
                .as_mut()
                .expect("limits")
                .daily_token_budget = 100_000_000;
        },
        |payload: &mut InvitationPayload| {
            payload
                .shared_access
                .as_mut()
                .expect("limits")
                .allowed_models
                .push("gpt-oss-120b".into());
        },
        |payload: &mut InvitationPayload| {
            payload.remote_hostname = Some("attacker.example".into());
        },
        |payload: &mut InvitationPayload| {
            payload.tls_fingerprint = Some("b".repeat(64));
        },
        |payload: &mut InvitationPayload| {
            payload.local_endpoint = Some("https://attacker.example:7443".into());
        },
        |payload: &mut InvitationPayload| payload.node_name = Some("Someone else".into()),
        |payload: &mut InvitationPayload| payload.role = "owner".into(),
        |payload: &mut InvitationPayload| payload.expires_at = "2099-01-01T00:00:00Z".into(),
    ] {
        let mut altered = payload.clone();
        alter(&mut altered);
        assert!(
            altered.verify(&node.identity).is_err(),
            "an altered payload must not verify"
        );
    }

    let mut altered = payload.clone();
    altered
        .shared_access
        .as_mut()
        .expect("limits")
        .daily_token_budget = 100_000_000;
    let (status, refused) = claim(&node, &altered, &guest_keys()).await;
    assert_eq!(
        status,
        StatusCode::UNPROCESSABLE_ENTITY,
        "the claim endpoint refuses it too: {refused}"
    );
    assert_eq!(error_code(&refused), "INVALID_REQUEST");

    // The same change re-signed by the node authority is accepted, so the refusal is the signature, not the shape.
    let mut resigned = payload.clone();
    resigned
        .shared_access
        .as_mut()
        .expect("limits")
        .daily_token_budget = 20_000;
    resign(&node.identity, &mut resigned);
    let (status, granted) = claim(&node, &resigned, &guest_keys()).await;
    assert_eq!(status, StatusCode::CREATED, "{granted}");
}
