#[tokio::test]
async fn project_delete_replays_after_the_first_delete_removed_membership() {
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();
    let created = create_through_api(&client, addr, &key, &device_id, "delete-replay").await;
    assert_eq!(
        wait_op(&h.state, created, Duration::from_secs(20)).await,
        "succeeded"
    );
    let (headers, _) = signed_parts(&key, &device_id, "GET", "/api/v1/projects", &[]);
    let mut request = client.get(format!("http://{addr}/api/v1/projects"));
    for (name, value) in headers { request = request.header(name, value); }
    let listing = request.send().await.unwrap();
    assert_eq!(listing.status(), reqwest::StatusCode::OK);
    assert_eq!(listing.headers()["x-spark-project-deletion"], "complete-v1");
    let project_id = h.projects.list().unwrap()[0].id;
    let path = format!("/api/v1/projects/{project_id}");
    let idempotency_key = uuid::Uuid::new_v4();

    let (first_status, first_body) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "DELETE",
        &path,
        None,
        idempotency_key,
    )
    .await;
    assert_eq!(first_status, reqwest::StatusCode::ACCEPTED, "{first_body}");
    let operation_id = uuid::Uuid::parse_str(first_body["id"].as_str().unwrap()).unwrap();
    assert_eq!(
        wait_op(&h.state, operation_id, Duration::from_secs(20)).await,
        "succeeded"
    );
    assert!(h.projects.get(&project_id).is_err());

    let (replay_status, replay_body) = signed_json_with_idempotency(
        &client,
        addr,
        &key,
        &device_id,
        "DELETE",
        &path,
        None,
        idempotency_key,
    )
    .await;
    assert_eq!(replay_status, first_status);
    assert_eq!(replay_body, first_body);
    let operation_count: i64 = h
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM operations WHERE kind = 'project.delete'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(operation_count, 1);
}

#[tokio::test]
async fn project_delete_removes_the_durable_workspace_and_closes_its_terminal() {
    let (h, _, _, owner) = harness().await;
    h.projects.create_project(uuid::Uuid::new_v4(), "remove-me", None, None, &owner).unwrap();
    let project = h.projects.list().unwrap().remove(0);
    let container = h.projects.ensure_development_workspace(&project).unwrap();
    let workspace = std::path::PathBuf::from(&container.worktree_path);
    std::fs::write(workspace.join("important.txt"), b"fixture").unwrap();
    let terminal_id = uuid::Uuid::new_v4();
    h.projects.development_terminal_create(terminal_id, project.id, owner, 80, 24, container).unwrap();
    h.projects.delete_project(uuid::Uuid::new_v4(), &project.id).unwrap();
    assert!(!project.root_path.exists());
    assert!(!workspace.exists(), "durable workspace was left on the Spark");
    assert!(h.projects.terminals_for_project(&project.id).is_empty());
    assert!(h.containers.calls().iter().any(|call| call.starts_with("stop ")));
    assert!(h.projects.ensure_development_workspace(&project).is_err(), "stale view resurrected deleted workspace");
}

#[tokio::test]
async fn project_delete_reports_filesystem_failure_and_preserves_retry_identity() {
    let (h, _, _, owner) = harness().await;
    h.projects.create_project(uuid::Uuid::new_v4(), "retry-me", None, None, &owner).unwrap();
    let project = h.projects.list().unwrap().remove(0);
    std::fs::remove_dir_all(&project.root_path).unwrap();
    std::fs::write(&project.root_path, b"unexpected file where directory should be").unwrap();
    assert!(h.projects.delete_project(uuid::Uuid::new_v4(), &project.id).is_err());
    assert!(h.projects.list().unwrap().iter().any(|p| p.id == project.id));
    std::fs::remove_file(&project.root_path).unwrap();
    h.projects.delete_project(uuid::Uuid::new_v4(), &project.id).unwrap();
    assert!(h.projects.list().unwrap().is_empty());
}

#[cfg(unix)]
#[tokio::test]
async fn project_delete_refuses_a_workspace_path_outside_managed_roots() {
    let (h, _, _, owner) = harness().await;
    h.projects.create_project(uuid::Uuid::new_v4(), "bounds", None, None, &owner).unwrap();
    let project = h.projects.list().unwrap().remove(0);
    let outside = h._dir.path().join("unrelated");
    std::fs::create_dir(&outside).unwrap();
    std::fs::write(outside.join("keep.txt"), b"keep").unwrap();
    h.projects.db.lock().execute("UPDATE projects SET root_path = ?1 WHERE id = ?2",
        rusqlite::params![outside.display().to_string(), project.id.to_string()]).unwrap();
    assert!(h.projects.delete_project(uuid::Uuid::new_v4(), &project.id).is_err());
    assert!(outside.join("keep.txt").exists());
}

#[tokio::test]
async fn project_delete_waits_for_preparation_and_leaves_other_projects_alone() {
    let (h, _, _, owner) = harness().await;
    h.projects.create_project(uuid::Uuid::new_v4(), "busy", None, None, &owner).unwrap();
    let project = h.projects.list().unwrap().remove(0);
    let reservation = h.projects.reserve_terminal(project.id, uuid::Uuid::new_v4()).unwrap();
    assert_eq!(h.projects.delete_project(uuid::Uuid::new_v4(), &project.id).unwrap_err(), "PROJECT_BUSY");
    assert!(h.projects.get(&project.id).is_ok());
    drop(reservation);
    h.projects.create_project(uuid::Uuid::new_v4(), "other", None, None, &owner).unwrap();
    let other = h.projects.list().unwrap().into_iter().find(|p| p.id != project.id).unwrap();
    let other_container = h.projects.ensure_development_workspace(&other).unwrap();
    h.projects.delete_project(uuid::Uuid::new_v4(), &project.id).unwrap();
    assert!(other.root_path.exists());
    assert!(std::path::Path::new(&other_container.worktree_path).exists());
    assert!(h.projects.get(&other.id).is_ok());
}

#[tokio::test]
async fn project_delete_waits_for_jobs_and_removes_finished_build_data() {
    let (h, _, _, owner) = harness().await;
    h.projects.create_project(uuid::Uuid::new_v4(), "built", None, None, &owner).unwrap();
    let project = h.projects.list().unwrap().remove(0);
    let work = h._dir.path().join("work");
    let _builds = sparkd::build::BuildService::new(h.projects.clone(), h.state.jobs.clone(),
        h.state.events.clone(), h.state.identity.clone(), work.clone());
    let build = uuid::Uuid::new_v4();
    let operation = {
        let conn = h.projects.db.lock();
        let operation = h.state.jobs.create(&conn, "build.submit", owner, None,
            &json!({ "project_id": project.id }).to_string()).unwrap();
        conn.execute("INSERT INTO builds (id, project_id, operation_id, commit_sha, scheme,
            configuration, destination, actions_json, timeout_seconds, status,
            requested_by_device_id, created_at, updated_at) VALUES
            (?1, ?2, ?3, 'abc', 'App', 'Debug', 'iOS', '[]', 60, 'completed', ?4, 'now', 'now')",
            rusqlite::params![build.to_string(), project.id.to_string(), operation.to_string(), owner.to_string()]).unwrap();
        operation
    };
    assert_eq!(h.projects.delete_project(uuid::Uuid::new_v4(), &project.id).unwrap_err(), "PROJECT_BUSY");
    h.projects.db.lock().execute("UPDATE operations SET state = 'succeeded' WHERE id = ?1", [operation.to_string()]).unwrap();
    let artifacts = work.join("builds").join(build.to_string());
    std::fs::create_dir_all(&artifacts).unwrap();
    std::fs::write(artifacts.join("result.zip"), b"fixture").unwrap();
    h.projects.delete_project(uuid::Uuid::new_v4(), &project.id).unwrap();
    assert!(!artifacts.exists());
    let count: i64 = h.projects.db.lock().query_row("SELECT count(*) FROM builds WHERE project_id = ?1", [project.id.to_string()], |r| r.get(0)).unwrap();
    assert_eq!(count, 0);
}
