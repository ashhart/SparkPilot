#[tokio::test]
async fn a_stale_review_is_refused_after_the_recorded_failure_changes() {
    let peer = peer("owner");
    disable_profile(&peer);
    let preview = issue_preview(&peer).await;
    let digest = preview["preview_digest"].as_str().unwrap().to_owned();

    // The guard observes a worse failure while the owner is still reading.
    {
        let conn = peer.state.database.as_ref().unwrap().lock();
        guard::record_profile_peak(&conn, MODEL, PROFILE, 74 * GIB, &fixture_environment()).unwrap();
    }

    let body = serde_json::to_vec(&json!({ "accepted_preview_digest": digest })).unwrap();
    let (status, refusal) = send(
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
    assert!(
        status.is_client_error(),
        "a review of a superseded failure was accepted: {refusal}"
    );
    assert!(is_unsafe(&peer));
}
