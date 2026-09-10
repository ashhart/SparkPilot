/// Authorize changes against their stored project even when another project's administrator holds a global owner role (P1-2).
#[tokio::test]
async fn a_change_cannot_be_approved_through_another_project() {
    let (h, addr, key, device_id) = harness(vec![
        AgentToolCall::WriteFile {
            path: "victim.txt".into(),
            content: "victim work\n".into(),
        },
        AgentToolCall::Git {
            op: GitOp::Add {
                path: "victim.txt".into(),
            },
        },
        AgentToolCall::Git {
            op: GitOp::Commit {
                message: "victim work".into(),
            },
        },
        AgentToolCall::RunCommand {
            command: "true".into(),
        },
    ])
    .await;
    let client = reqwest::Client::new();
    let victim_project = create_project(&client, addr, &key, &device_id, &h.state, "victim").await;

    let (_, response) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{victim_project}/agents"),
        Some(json!({ "task": "victim change" })),
    )
    .await;
    wait_ok(&h.state, response["id"].as_str().unwrap()).await;
    let change = wait_change_status(&h.state, &victim_project, "victim change", "review").await;
    let change_id = change["id"].as_str().unwrap().to_owned();

    // Give the attacker global owner and administrator membership in only its own project.
    let attacker_key = fresh_device_key();
    let attacker_device = uuid::Uuid::new_v4();
    {
        let conn = h.state.database.as_ref().expect("db").lock();
        sparkd::store::insert_device(
            &conn,
            &attacker_device,
            "attacker",
            "macos",
            &spki_der(&attacker_key),
            &format!("fp-attacker-{attacker_device}"),
            "owner",
        )
        .expect("seed attacker");
    }
    let (status, created) = signed_json(
        &client,
        addr,
        &attacker_key,
        &attacker_device,
        "POST",
        "/api/v1/projects",
        Some(json!({ "name": "attacker" })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{created}");
    wait_ok(&h.state, created["id"].as_str().unwrap()).await;
    let attacker_project = {
        let conn = h.state.database.as_ref().expect("db").lock();
        sparkd::store::project_rows(&conn, 10)
            .unwrap()
            .into_iter()
            .find(|row| row.name == "attacker")
            .expect("attacker project")
            .id
            .to_string()
    };

    for decision in ["approve", "reject"] {
        let (status, body) = signed_json(
            &client,
            addr,
            &attacker_key,
            &attacker_device,
            "POST",
            &format!("/api/v1/projects/{attacker_project}/changes/{change_id}/{decision}"),
            Some(json!({})),
        )
        .await;
        assert_eq!(
            status,
            reqwest::StatusCode::NOT_FOUND,
            "{decision} through another project must not resolve: {body}"
        );
        assert_eq!(body["error"]["code"], "CHANGE_NOT_FOUND");
    }

    // Reject direct access to the victim project because global owner does not imply membership.
    let (status, body) = signed_json(
        &client,
        addr,
        &attacker_key,
        &attacker_device,
        "POST",
        &format!("/api/v1/projects/{victim_project}/changes/{change_id}/approve"),
        Some(json!({})),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["error"]["code"], "PROJECT_FORBIDDEN");

    // The change is still awaiting review.
    let conn = h.state.database.as_ref().expect("db").lock();
    let status: String = conn
        .query_row(
            "SELECT status FROM changes WHERE id = ?1",
            [change_id.clone()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(status, "review");
    let _ = &h.agents;
}
