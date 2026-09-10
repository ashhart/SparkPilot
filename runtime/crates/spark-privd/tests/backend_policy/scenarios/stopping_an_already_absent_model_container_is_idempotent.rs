#[test]
fn stopping_an_already_absent_model_container_is_idempotent() {
    let root = tempfile::tempdir().unwrap();
    let docker = root.path().join("docker");
    fs::write(
        &docker,
        "#!/bin/sh\nprintf 'Error response from daemon: No such container: spark-model-test\\n' >&2\nexit 1\n",
    )
    .unwrap();
    fs::set_permissions(&docker, fs::Permissions::from_mode(0o755)).unwrap();
    let runtime_dir = root.path().join("runtime");
    let backend = DockerBackend::new(docker.to_string_lossy(), false)
        .with_paths(root.path().join("models"), &runtime_dir);

    for force in [false, true] {
        let instance_id = Uuid::new_v4();
        let credential = runtime_dir
            .join("credentials")
            .join(format!("spark-vllm-{instance_id}.env"));
        fs::create_dir_all(credential.parent().unwrap()).unwrap();
        fs::write(&credential, "VLLM_API_KEY=test\n").unwrap();

        let response = backend
            .execute(&stop_model_operation(instance_id, force))
            .expect("an absent model container is already stopped");

        assert_eq!(response.code, "stopped");
        assert_eq!(response.details["already_absent"], true);
        assert!(!credential.exists(), "stale credential was retained");
    }
}

#[test]
fn project_container_removal_confirms_absence_and_requires_ownership_when_present() {
    for (listing_ok, present, owned) in [(true, false, false), (false, false, false), (true, true, false), (true, true, true)] {
        let root = tempfile::tempdir().unwrap();
        let docker = root.path().join("docker");
        let log = root.path().join("calls");
        let container = format!("spark-project-{}", Uuid::new_v4());
        let listing = if present { container.clone() } else { String::new() };
        let label = if owned { Uuid::new_v4().to_string() } else { String::new() };
        fs::write(&docker, format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\ncase \"$1\" in\ncontainer) printf '%s\\n' '{}'; exit {};;\ninspect) printf '%s\\n' '{}'; exit 0;;\nrm) exit 0;;\nesac\nexit 1\n",
            log.display(), listing, if listing_ok { 0 } else { 1 }, label)).unwrap();
        fs::set_permissions(&docker, fs::Permissions::from_mode(0o755)).unwrap();
        let backend = DockerBackend::new(docker.to_string_lossy(), false);
        let result = backend.execute(&PrivilegedOperation::StopProjectContainer {
            request_id: Uuid::new_v4(), container_id: container.clone(),
        });
        assert_eq!(result.is_ok(), listing_ok && (!present || owned));
        let calls = fs::read_to_string(&log).unwrap();
        assert_eq!(calls.lines().any(|l| l.starts_with("rm ")), listing_ok && present && owned);
    }
}
