#[tokio::test]
async fn a_digest_reviewed_for_one_profile_cannot_re_enable_another() {
    let peer = peer("owner");
    // Give both profiles identical unsafe evidence so only the review's identity binding distinguishes them.
    disable_profile(&peer);
    {
        let conn = peer.state.database.as_ref().unwrap().lock();
        guard::record_profile_peak(&conn, MODEL, OTHER_PROFILE, 61 * GIB, &fixture_environment())
            .unwrap();
        guard::mark_profile_unsafe(&conn, MODEL, OTHER_PROFILE, "MEMORY_PRESSURE_CRITICAL")
            .unwrap();
    }
    let preview = issue_preview(&peer).await;
    let digest = preview["preview_digest"].as_str().unwrap().to_owned();
    let body = serde_json::to_vec(&json!({ "accepted_preview_digest": digest })).unwrap();

    // Refuse a valid owner's fresh proof and digest when aimed at a profile that was not reviewed.
    let (status, refusal) = send(
        &peer,
        signed_request(
            &peer,
            &apply_path(MODEL_PATH, OTHER_PROFILE),
            &body,
            uuid::Uuid::new_v4(),
            true,
        ),
    )
    .await;
    assert!(
        status.is_client_error(),
        "a digest reviewed for {PROFILE} was accepted for {OTHER_PROFILE}: {refusal}"
    );
    assert!(
        is_unsafe_profile(&peer, OTHER_PROFILE),
        "the unreviewed profile was re-enabled"
    );
    assert!(
        is_unsafe_profile(&peer, PROFILE),
        "the reviewed profile was cleared instead"
    );
}
