#[tokio::test]
async fn file_api_enforces_revision_preconditions() {
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();

    let operation_id = create_through_api(&client, addr, &key, &device_id, "files").await;
    assert_eq!(
        wait_op(&h.state, operation_id, Duration::from_secs(20)).await,
        "succeeded"
    );
    let project_id = {
        let items = h.projects.list().unwrap();
        items[0].id.to_string()
    };

    // New file: the empty revision is the precondition.
    let (status, saved) = put_file(
        &client,
        addr,
        &key,
        &device_id,
        &project_id,
        "src/main.rs",
        "fn main() {}",
        REVISION_EMPTY,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{saved}");
    let revision = saved["revision"].as_str().expect("revision").to_owned();
    assert_eq!(revision.len(), 64);

    let (status, contents) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        &format!("/api/v1/projects/{project_id}/files/src/main.rs"),
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{contents}");
    assert_eq!(contents["content"], "fn main() {}");
    assert_eq!(contents["revision"], revision);

    // Decode encoded slashes inside the wildcard path back into the intended project-relative file path.
    let encoded_nested = "Sources%2FApp%2FMain.swift";
    let (status, saved) = put_file(
        &client,
        addr,
        &key,
        &device_id,
        &project_id,
        encoded_nested,
        "let answer = 42\n",
        REVISION_EMPTY,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{saved}");
    assert_eq!(saved["path"], "Sources/App/Main.swift");
    let (status, contents) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        &format!("/api/v1/projects/{project_id}/files/{encoded_nested}"),
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{contents}");
    assert_eq!(contents["path"], "Sources/App/Main.swift");
    assert_eq!(contents["content"], "let answer = 42\n");

    // Replay the exact first file-save success even though its original If-Match became stale after that save.
    let replay_key = uuid::Uuid::new_v4();
    let (first_status, first) = put_file_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        &project_id,
        "src/replay.rs",
        "pub fn replay() {}",
        REVISION_EMPTY,
        replay_key,
    )
    .await;
    assert_eq!(first_status, reqwest::StatusCode::OK, "{first}");
    let (replay_status, replay) = put_file_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        &project_id,
        "src/replay.rs",
        "pub fn replay() {}",
        REVISION_EMPTY,
        replay_key,
    )
    .await;
    assert_eq!(replay_status, reqwest::StatusCode::OK, "{replay}");
    assert_eq!(replay, first);

    // Stale precondition is rejected with the current revision (409).
    let (status, conflict) = put_file(
        &client,
        addr,
        &key,
        &device_id,
        &project_id,
        "src/main.rs",
        "fn main() { println!(1) }",
        REVISION_EMPTY,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::CONFLICT, "{conflict}");
    assert_eq!(conflict["error"]["code"], "FILE_CONFLICT");
    assert_eq!(conflict["error"]["base_revision"], REVISION_EMPTY);
    assert_eq!(conflict["error"]["current_revision"], revision);
    assert_eq!(conflict["error"]["current_content"], "fn main() {}");

    // Correct precondition saves and bumps the revision.
    let (status, second) = put_file(
        &client,
        addr,
        &key,
        &device_id,
        &project_id,
        "src/main.rs",
        "fn main() { println!(\"hi\") }",
        &revision,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{second}");
    assert_ne!(second["revision"].as_str().unwrap(), revision);

    // Browse reflects the saved files with content-addressed revisions.
    let (status, files) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        &format!("/api/v1/projects/{project_id}/files"),
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{files}");
    let entries = files["items"].as_array().unwrap();
    assert!(
        entries.iter().any(|e| e["path"] == "src/main.rs"),
        "{files}"
    );

    // Traversal is rejected up front.
    let (status, traversal) = put_file(
        &client,
        addr,
        &key,
        &device_id,
        &project_id,
        "..%2F..%2Fescape.txt",
        "x",
        REVISION_EMPTY,
    )
    .await;
    assert!(
        status.is_server_error() || status.is_client_error(),
        "traversal must be rejected (status {status})"
    );
    let _ = (traversal, &h);
}
