/// A terminal id grants no authority across projects, including to an owner elsewhere (P0-2).
#[tokio::test]
async fn terminals_cannot_be_reached_through_another_project() {
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();

    let operation_id = create_through_api(&client, addr, &key, &device_id, "victim").await;
    assert_eq!(
        wait_op(&h.state, operation_id, Duration::from_secs(20)).await,
        "succeeded"
    );
    let victim = h
        .projects
        .list()
        .unwrap()
        .into_iter()
        .find(|project| project.name == "victim")
        .expect("victim project");
    write_devcontainer(&victim.root_path);

    let (status, created) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{}/terminals", victim.id),
        Some(json!({ "shell": "login" })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{created}");
    let terminal_id = created["terminal_id"].as_str().unwrap().to_owned();

    let (attacker_key, attacker_device, attacker_project) =
        second_project_and_device(&h, addr).await;

    // Use a valid upgrade handshake and authorized attacker project so failure proves the terminal's project binding.
    let status = attempt_attach(
        addr,
        &attacker_key,
        &attacker_device,
        &attacker_project.to_string(),
        &terminal_id,
    )
    .await;
    assert_eq!(
        status, 404,
        "attach through another project must not resolve"
    );

    // Closing is the same resource, so it is refused the same way.
    let close_path = format!("/api/v1/projects/{attacker_project}/terminals/{terminal_id}");
    let (status, body) = signed_json(
        &client,
        addr,
        &attacker_key,
        &attacker_device,
        "DELETE",
        &close_path,
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::NOT_FOUND, "{body}");
    assert_eq!(body["error"]["code"], "TERMINAL_NOT_FOUND");

    // Refuse nonmembers before looking up any terminal in the victim project.
    let status = attempt_attach(
        addr,
        &attacker_key,
        &attacker_device,
        &victim.id.to_string(),
        &terminal_id,
    )
    .await;
    assert_eq!(
        status, 403,
        "a non-member is refused at the capability check"
    );

    // The victim's session is untouched by any of that.
    let terminal_uuid = uuid::Uuid::parse_str(&terminal_id).unwrap();
    assert_eq!(
        h.projects.terminals_for_project(&victim.id),
        vec![terminal_uuid]
    );
}
