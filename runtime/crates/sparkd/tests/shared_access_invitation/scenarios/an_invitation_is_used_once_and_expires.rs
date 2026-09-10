#[tokio::test]
async fn an_invitation_is_used_once_and_expires() {
    let node = node();
    let (_, body) = create_invitation(&node).await;
    let payload: InvitationPayload =
        serde_json::from_value(body["invitation"].clone()).expect("payload");

    let (first, _) = claim(&node, &payload, &guest_keys()).await;
    assert_eq!(first, StatusCode::CREATED);
    let (second, refused) = claim(&node, &payload, &guest_keys()).await;
    assert_eq!(second, StatusCode::CONFLICT, "{refused}");
    assert_eq!(error_code(&refused), "INVITATION_ALREADY_USED");

    let (_, body) = create_invitation(&node).await;
    let mut expired: InvitationPayload =
        serde_json::from_value(body["invitation"].clone()).expect("payload");
    expired.expires_at = (time::OffsetDateTime::now_utc() - time::Duration::minutes(5))
        .format(&time::format_description::well_known::Rfc3339)
        .expect("rfc3339");
    resign(&node.identity, &mut expired);
    let (status, refused) = claim(&node, &expired, &guest_keys()).await;
    assert_eq!(status, StatusCode::GONE, "{refused}");
    assert_eq!(error_code(&refused), "INVITATION_EXPIRED");
}
