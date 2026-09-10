#[tokio::test]
async fn devcontainer_plans_are_policy_checked() {
    let (h, addr, key, device_id) = harness().await;
    let client = reqwest::Client::new();

    let operation_id = create_through_api(&client, addr, &key, &device_id, "container").await;
    assert_eq!(
        wait_op(&h.state, operation_id, Duration::from_secs(20)).await,
        "succeeded"
    );
    let view = h.projects.list().unwrap().remove(0);

    let dev_dir = view.root_path.join(".devcontainer");
    std::fs::create_dir_all(&dev_dir).unwrap();
    std::fs::write(
        dev_dir.join("devcontainer.json"),
        r#"{
          "image": "nvcr.io/nvidia/cuda@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "mounts": ["type=bind,source=${localWorkspaceFolder}/src,target=/workspace/src"],
          "forwardPorts": [5173]
        }"#,
    )
    .unwrap();

    let plan = h.projects.devcontainer_plan(&view).expect("plan parses");
    let plan = plan.expect("project has a plan");
    assert_eq!(plan.forward_ports, vec![5173]);
    assert!(plan.image_digest.contains("sha256:"));

    // An unpinned image is rejected by the policy gate.
    std::fs::write(
        dev_dir.join("devcontainer.json"),
        r#"{ "image": "nvcr.io/nvidia/cuda:latest" }"#,
    )
    .unwrap();
    assert!(
        h.projects.devcontainer_plan(&view).is_err(),
        "unpinned image must be rejected"
    );
    let _ = &h.containers;
}
