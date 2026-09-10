#[tokio::test]
async fn an_unknown_profile_is_refused_before_any_review_is_issued() {
    let peer = peer("owner");
    let (status, refusal) = send(
        &peer,
        signed_request(
            &peer,
            &preview_path(MODEL_PATH, "no-such-profile"),
            b"",
            uuid::Uuid::new_v4(),
            false,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{refusal}");
    assert_eq!(refusal["error"]["code"], "PROFILE_NOT_FOUND");
}
