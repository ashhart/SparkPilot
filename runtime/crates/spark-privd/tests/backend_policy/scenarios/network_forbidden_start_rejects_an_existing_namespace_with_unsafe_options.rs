#[test]
fn network_forbidden_start_rejects_an_existing_namespace_with_unsafe_options() {
    let root = tempfile::tempdir().unwrap();
    let docker = root.path().join("docker");
    let log = root.path().join("docker.log");
    let script = format!(
        r#"#!/bin/sh
printf '%s\n' "$*" >> '{}'
if [ "$1" = network ] && [ "$2" = inspect ]; then
  printf '%s\n' '[{{"Name":"spark-inference-isolated","Driver":"bridge","Scope":"local","Internal":false,"Attachable":false,"Ingress":false,"EnableIPv6":false,"Options":{{"com.docker.network.bridge.enable_icc":"true","com.docker.network.bridge.host_binding_ipv4":"0.0.0.0"}}}}]'
  exit 0
fi
exit 77
"#,
        log.display()
    );
    fs::write(&docker, script).unwrap();
    fs::set_permissions(&docker, fs::Permissions::from_mode(0o755)).unwrap();
    let models = root.path().join("models");
    let snapshot = models.join("snapshots/example/model-32b/rev");
    fs::create_dir_all(&snapshot).unwrap();
    let runtime = root.path().join("run");
    let probe = root.path().join("uid-probe");
    fs::write(&probe, b"").unwrap();
    let backend = DockerBackend::new(docker.to_string_lossy(), false)
        .with_paths(&models, &runtime)
        .with_service_uid(std::os::unix::fs::MetadataExt::uid(
            &fs::metadata(&probe).unwrap(),
        ))
        .with_service_gid(std::os::unix::fs::MetadataExt::gid(
            &fs::metadata(&probe).unwrap(),
        ))
        .with_engine_cache_root(root.path().join("engine-cache"));
    let mut operation = start_operation(Uuid::new_v4());
    let PrivilegedOperation::StartModel { model_snapshot, .. } = &mut operation else {
        unreachable!()
    };
    *model_snapshot = snapshot.to_string_lossy().into_owned();

    let result = backend.execute(&operation);

    // Report failed replacement of an incompatible network instead of reusing its unsafe policy.
    assert!(
        matches!(&result, Err(BackendError::Failure(message)) if message.contains("could not be replaced")),
        "{result:?}"
    );
    assert_eq!(
        fs::read_to_string(log).unwrap(),
        format!(
            "network inspect {INFERENCE_ISOLATED_NETWORK}\nnetwork inspect {INFERENCE_ISOLATED_NETWORK}\nnetwork rm {INFERENCE_ISOLATED_NETWORK}\n"
        )
    );
    assert!(!runtime.join("credentials").exists());
}
