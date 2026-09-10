#[tokio::test]
async fn approval_recovers_after_the_reviewed_merge_landed_before_status_commit() {
    let task = "recover durable approval";
    let (h, addr, key, device_id) =
        harness(reviewed_file_plan("recovered.txt", "reviewed\n")).await;
    let client = reqwest::Client::new();
    let project_id = create_project(&client, addr, &key, &device_id, &h.state, "recover").await;
    let (_, started) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/agents"),
        Some(json!({ "task": task })),
    )
    .await;
    wait_ok(&h.state, started["id"].as_str().unwrap()).await;
    let change = wait_change_status(&h.state, &project_id, task, "review").await;
    let change_id = uuid::Uuid::parse_str(change["id"].as_str().unwrap()).unwrap();
    let row = h.agents.get_change(&change_id).unwrap();
    let evidence: sparkd::change_evidence::ReviewEvidence =
        serde_json::from_str(&row.review_evidence_json).unwrap();
    let digest = row.review_digest.as_deref().unwrap();
    let project = h
        .agents
        .projects
        .get(&uuid::Uuid::parse_str(&project_id).unwrap())
        .unwrap();
    let evidence_record = json!({
        "review_digest": digest,
        "review_evidence": evidence,
    });
    {
        let conn = h.state.database.as_ref().unwrap().lock();
        let approval_id = sparkd::store::insert_approval_with_evidence(
            &conn,
            &row.operation_id,
            "change_merge",
            &change_id.to_string(),
            Some(&device_id),
            &evidence_record.to_string(),
        )
        .unwrap();
        sparkd::store::decide_approval(
            &conn,
            &approval_id,
            "approved",
            &device_id,
            Some("approved before simulated restart"),
        )
        .unwrap();
        sparkd::store::update_change_status(&conn, &change_id, "approved").unwrap();
    }
    let message = format!("spark: agent change {task}\n\nSpark-Review-Digest: {digest}");
    let merged_before_retry = h
        .agents
        .projects
        .merge_reviewed_worktree(
            &project,
            &sparkd::project::ReviewedMerge {
                branch: &row.worktree_branch,
                reviewed_head: &evidence.head_commit,
                reviewed_protected_head: &evidence.protected_head_commit,
                review_digest: digest,
                message: &message,
                author: "spark-agent <agent@spark.local>",
            },
        )
        .unwrap();

    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        &format!("/api/v1/projects/{project_id}/changes/{change_id}/approve"),
        Some(json!({ "review_digest": digest })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{body}");
    assert_eq!(body["change"]["status"], "merged");
    assert_eq!(
        h.agents.projects.protected_head(&project).unwrap(),
        merged_before_retry,
        "retry must reconcile the digest-bound commit without another merge"
    );
}
