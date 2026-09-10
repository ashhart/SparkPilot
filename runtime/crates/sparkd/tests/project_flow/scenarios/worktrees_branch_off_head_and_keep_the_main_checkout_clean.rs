#[tokio::test]
async fn worktrees_branch_off_head_and_keep_the_main_checkout_clean() {
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();

    let operation_id = create_through_api(&client, addr, &key, &device_id, "worktrees").await;
    assert_eq!(
        wait_op(&h.state, operation_id, Duration::from_secs(20)).await,
        "succeeded"
    );
    let view = h.projects.list().unwrap().remove(0);

    let created = h
        .projects
        .create_worktree(&view, None, None)
        .expect("worktree");
    let (wt_id, path) = (created.id, created.path);
    // git reports the realpath; compare by the agent branch suffix.
    let branch = path.file_name().unwrap().to_string_lossy().into_owned();
    let listed = h.projects.worktree_list(&view).expect("list");
    assert!(
        listed.iter().any(|p| p.ends_with(&branch)),
        "agent worktree listed: {listed:?} / {branch}"
    );
    // The main checkout is untouched: only the agent worktree gets edits.
    std::fs::write(path.join("agent-change.txt"), "agent edit").unwrap();
    let status = h.projects.worktree_status(&view).expect("status");
    assert!(status.is_empty(), "main checkout clean: {status:?}");
    assert!(
        path.join("agent-change.txt").exists(),
        "agent edit in worktree"
    );
    h.projects.remove_worktree(&view, &path).unwrap();
    assert!(!path.exists());
    assert!(h.projects.worktree_list(&view).unwrap().is_empty());
    assert!(view.root_path.exists());
    let _ = wt_id;
}
