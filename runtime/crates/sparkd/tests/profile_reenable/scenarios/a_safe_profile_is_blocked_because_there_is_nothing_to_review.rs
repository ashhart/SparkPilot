#[tokio::test]
async fn a_safe_profile_is_blocked_because_there_is_nothing_to_review() {
    let peer = peer("owner");
    let preview = issue_preview(&peer).await;
    let codes: Vec<&str> = preview["blockers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|blocker| blocker["code"].as_str().unwrap())
        .collect();
    assert!(
        codes.contains(&"MODEL_PROFILE_ALREADY_SAFE"),
        "expected a blocker, got {preview}"
    );
}
