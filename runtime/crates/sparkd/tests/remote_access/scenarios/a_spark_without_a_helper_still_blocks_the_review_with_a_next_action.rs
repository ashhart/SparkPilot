#[tokio::test]
async fn a_spark_without_a_helper_still_blocks_the_review_with_a_next_action() {
    let (state, client, _database, _guard) = one_tap_state(
        "owner",
        Arc::new(ScriptedProvisioner::not_installable()),
    )
    .await;
    let (status, preview) = send(
        state,
        signed_request(
            &client,
            "POST",
            "/api/v1/remote/enable/preview",
            Some(&json!({ "mode": "private_overlay" })),
            vec![],
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{preview}");
    let blockers = preview["blockers"].as_array().unwrap();
    assert_eq!(blockers.len(), 1, "{preview}");
    assert_eq!(blockers[0]["code"], "PRIVATE_OVERLAY_UNAVAILABLE");
    assert!(
        blockers[0]["recovery_action"]
            .as_str()
            .unwrap()
            .contains("Install Tailscale"),
        "{preview}"
    );
    assert_eq!(preview["evidence"]["remote"]["requested_mode_available"], false);
    assert_eq!(
        preview["evidence"]["remote"]["overlay_setup_state"],
        "not_installed"
    );
}
