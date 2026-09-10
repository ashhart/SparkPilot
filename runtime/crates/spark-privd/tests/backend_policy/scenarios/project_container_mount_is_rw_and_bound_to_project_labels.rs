#[test]
fn project_container_mount_is_rw_and_bound_to_project_labels() {
    let (_root, backend, operation) = managed_project_fixture();
    let plan = backend.plan_start_project_container(&operation).unwrap();
    let (project_id, worktree_id) = match operation {
        PrivilegedOperation::StartProjectContainer {
            project_id,
            worktree_id,
            ..
        } => (project_id, worktree_id),
        _ => unreachable!(),
    };
    assert!(
        plan.argv
            .iter()
            .any(|argument| argument.ends_with(":/workspace:rw")),
        "the dedicated worktree must be writable inside the container: {:?}",
        plan.argv
    );
    assert!(
        plan.argv
            .contains(&format!("--label=spark.project_id={project_id}"))
    );
    assert!(
        plan.argv
            .contains(&format!("--label=spark.worktree_id={worktree_id}"))
    );
}

#[test]
fn development_image_has_a_durable_home_and_keeps_host_and_engine_isolation() {
    let (_root, backend, mut operation) = managed_project_fixture();
    if let PrivilegedOperation::StartProjectContainer { image_digest, .. } = &mut operation {
        *image_digest = spark_core::DEVELOPMENT_IMAGE.into();
    }
    let plan = backend.plan_start_project_container(&operation).unwrap();
    for required in ["--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges:true", "--network=bridge", "--env=HOME=/workspace/.spark-home", "--tmpfs=/tmp:rw,nosuid,nodev,size=536870912"] {
        assert!(plan.argv.iter().any(|arg| arg == required), "missing {required}");
    }
    assert_eq!(&plan.argv[plan.argv.len()-3..], ["/bin/sh", "-c", "while :; do sleep 3600; done"]);
    assert!(!plan.argv.iter().any(|arg| arg.contains("docker.sock") || arg == "--privileged" || arg == "--network=host"));
}
