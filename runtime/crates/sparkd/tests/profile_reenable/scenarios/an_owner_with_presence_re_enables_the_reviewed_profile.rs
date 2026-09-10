#[tokio::test]
async fn an_owner_with_presence_re_enables_the_reviewed_profile() {
    let peer = peer("owner");
    disable_profile(&peer);
    let preview = issue_preview(&peer).await;
    let digest = preview["preview_digest"].as_str().unwrap().to_owned();
    let body = serde_json::to_vec(&json!({ "accepted_preview_digest": digest })).unwrap();

    let (status, accepted) = send(
        &peer,
        signed_request(
            &peer,
            &apply_path(MODEL_PATH, PROFILE),
            &body,
            uuid::Uuid::new_v4(),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED, "apply refused: {accepted}");
    let operation_id = accepted["id"].as_str().unwrap().to_owned();
    await_operation(&peer, &operation_id).await;
    assert!(!is_unsafe(&peer), "the profile is still disabled");

    let conn = peer.state.database.as_ref().unwrap().lock();
    let (action, resource): (String, Option<String>) = conn
        .query_row(
            "SELECT action, resource FROM audit_records WHERE action = 'model.profile.reenable'
             AND result = 'accepted' ORDER BY sequence DESC LIMIT 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("an accepted re-enable is audited");
    assert_eq!(action, "model.profile.reenable");
    // Record the exact profile, not only its model, in the authorization audit resource.
    assert_eq!(
        resource.as_deref(),
        Some(format!("model/{MODEL}/profile/{PROFILE}").as_str())
    );
}
