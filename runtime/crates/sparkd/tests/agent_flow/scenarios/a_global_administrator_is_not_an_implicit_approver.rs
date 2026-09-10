/// A global administrator without project membership cannot approve that project's change (§61).
#[tokio::test]
async fn a_global_administrator_is_not_an_implicit_approver() {
    let (h, addr, key, device_id) = harness(vec![
        AgentToolCall::WriteFile {
            path: "work.txt".into(),
            content: "work\n".into(),
        },
        AgentToolCall::Git {
            op: GitOp::Add {
                path: "work.txt".into(),
            },
        },
        AgentToolCall::Git {
            op: GitOp::Commit {
                message: "work".into(),
            },
        },
        AgentToolCall::RunCommand {
            command: "true".into(),
        },
    ])
    .await;
    let client = reqwest::Client::new();
    let project_id = create_project(&client, addr, &key, &device_id, &h.state, "guarded").await;
    let (_, response) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/agents"),
        Some(json!({ "task": "guarded change" })),
    )
    .await;
    wait_ok(&h.state, response["id"].as_str().unwrap()).await;
    let change = wait_change_status(&h.state, &project_id, "guarded change", "review").await;

    let admin_key = fresh_device_key();
    let admin_device = uuid::Uuid::new_v4();
    {
        let conn = h.state.database.as_ref().expect("db").lock();
        sparkd::store::insert_device(
            &conn,
            &admin_device,
            "administrator",
            "macos",
            &spki_der(&admin_key),
            &format!("fp-admin-{admin_device}"),
            "administrator",
        )
        .expect("seed administrator");
    }

    let (status, body) = signed_json(
        &client,
        addr,
        &admin_key,
        &admin_device,
        "POST",
        &format!(
            "/api/v1/projects/{project_id}/changes/{}/approve",
            change["id"].as_str().unwrap()
        ),
        Some(json!({})),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["error"]["code"], "PROJECT_FORBIDDEN");
}
