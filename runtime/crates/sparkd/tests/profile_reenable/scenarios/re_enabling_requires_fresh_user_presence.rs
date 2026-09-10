#[tokio::test]
async fn re_enabling_requires_fresh_user_presence() {
    let peer = peer("owner");
    disable_profile(&peer);
    let preview = issue_preview(&peer).await;
    let digest = preview["preview_digest"].as_str().unwrap().to_owned();
    let body = serde_json::to_vec(&json!({ "accepted_preview_digest": digest })).unwrap();

    let (status, refusal) = send(
        &peer,
        signed_request(
            &peer,
            &apply_path(MODEL_PATH, PROFILE),
            &body,
            uuid::Uuid::new_v4(),
            false,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{refusal}");
    assert_eq!(refusal["error"]["code"], "USER_PRESENCE_REQUIRED");
    assert!(is_unsafe(&peer));
}
