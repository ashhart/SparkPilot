#[tokio::test]
async fn a_terminal_names_a_shell_never_a_command() {
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();
    let operation_id = create_through_api(&client, addr, &key, &device_id, "shell-only").await;
    assert_eq!(
        wait_op(&h.state, operation_id, Duration::from_secs(20)).await,
        "succeeded"
    );
    let view = h.projects.list().unwrap().remove(0);
    write_devcontainer(&view.root_path);
    let project_id = view.id.to_string();
    let path = format!("/api/v1/projects/{project_id}/terminals");

    // Reject obsolete free-form terminal commands rather than silently opening a default shell.
    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &path,
        Some(json!({ "command": "bash" })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::UNPROCESSABLE_ENTITY, "{body}");
    assert_eq!(body["error"]["code"], "COMMAND_NOT_SUPPORTED");

    for candidate in ["sh", "/bin/sh", "python3", "", "login;bash"] {
        let (status, body) = signed_json(
            &client,
            addr,
            &key,
            &device_id,
            "POST",
            &path,
            Some(json!({ "shell": candidate })),
        )
        .await;
        assert_eq!(
            status,
            reqwest::StatusCode::UNPROCESSABLE_ENTITY,
            "{candidate:?} was accepted: {body}"
        );
        assert_eq!(body["error"]["code"], "SHELL_NOT_SUPPORTED");
    }
}
