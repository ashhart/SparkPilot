#[tokio::test]
async fn the_preview_reports_the_recorded_failure_the_owner_is_reviewing() {
    let peer = peer("owner");
    disable_profile(&peer);
    let preview = issue_preview(&peer).await;

    assert_eq!(preview["action"], "profile.reenable");
    assert_eq!(preview["recipe"]["model_id"], MODEL);
    assert_eq!(preview["recipe"]["profile_id"], PROFILE);
    // Include the recorded measurement and failure code the owner is reviewing.
    assert_eq!(
        preview["evidence"]["profile_failure_code"],
        "MEMORY_PRESSURE_CRITICAL"
    );
    assert_eq!(
        preview["evidence"]["required_memory_bytes"],
        json!(61 * GIB)
    );
    assert!(
        preview["blockers"].as_array().unwrap().is_empty(),
        "an unsafe profile is reviewable: {preview}"
    );
}
