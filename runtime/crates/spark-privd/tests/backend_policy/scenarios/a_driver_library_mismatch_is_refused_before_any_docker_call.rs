/// Build a start backend whose driver preflight reads fixture files instead of the host.
fn gpu_driver_backend(
    root: &std::path::Path,
    docker: &std::path::Path,
    module_version: &std::path::Path,
    library_dir: &std::path::Path,
) -> DockerBackend {
    let models = root.join("models");
    fs::create_dir_all(models.join("snapshots/example/model-32b/rev")).unwrap();
    let probe = root.join("uid-probe");
    fs::write(&probe, b"").unwrap();
    DockerBackend::new(docker.to_string_lossy(), false)
        .with_paths(&models, root.join("run"))
        .with_service_uid(fs::metadata(&probe).unwrap().uid())
        .with_service_gid(fs::metadata(&probe).unwrap().gid())
        .with_engine_cache_root(root.join("engine-cache"))
        .with_gpu_driver_paths(module_version, vec![library_dir.to_path_buf()])
}

/// A network-allowed start keeps the fake docker to the single `run` call the scenarios inspect.
fn gpu_driver_start_operation(root: &std::path::Path) -> PrivilegedOperation {
    let mut operation = start_operation(Uuid::new_v4());
    let PrivilegedOperation::StartModel {
        model_snapshot,
        allow_network_during_inference,
        ..
    } = &mut operation
    else {
        unreachable!()
    };
    *model_snapshot = root
        .join("models/snapshots/example/model-32b/rev")
        .to_string_lossy()
        .into_owned();
    *allow_network_during_inference = true;
    operation
}

fn gpu_driver_fake_docker(
    root: &std::path::Path,
    run_script: &str,
) -> (std::path::PathBuf, std::path::PathBuf) {
    let docker = root.join("docker");
    let log = root.join("docker.log");
    let script = format!(
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\nif [ \"$1\" = run ]; then\n{}\nfi\nexit 0\n",
        log.display(),
        run_script
    );
    fs::write(&docker, script).unwrap();
    fs::set_permissions(&docker, fs::Permissions::from_mode(0o755)).unwrap();
    (docker, log)
}

#[test]
fn a_driver_library_mismatch_is_refused_before_any_docker_call() {
    let root = tempfile::tempdir().unwrap();
    let (docker, log) = gpu_driver_fake_docker(root.path(), "printf '%s\\n' container-id");
    let module_version = root.path().join("sys-module-nvidia-version");
    fs::write(&module_version, "580.159.03\n").unwrap();
    let library_dir = root.path().join("lib");
    fs::create_dir_all(&library_dir).unwrap();
    let soname = library_dir.join("libnvidia-ml.so.1");
    std::os::unix::fs::symlink("libnvidia-ml.so.580.173.02", &soname).unwrap();
    let backend = gpu_driver_backend(root.path(), &docker, &module_version, &library_dir);
    let operation = gpu_driver_start_operation(root.path());

    let response = backend
        .execute(&operation)
        .expect("a mismatch is a typed rejection, not a backend error");

    assert!(!response.accepted, "{response:?}");
    assert_eq!(response.code, "GPU_DRIVER_MISMATCH");
    assert_eq!(response.details["kernel_module_version"], "580.159.03");
    assert_eq!(response.details["nvml_library_version"], "580.173.02");
    assert!(response.details["docker_stderr"].is_null(), "{response:?}");
    assert!(
        response.message.contains("580.173.02")
            && response.message.contains("580.159.03")
            && response.message.to_lowercase().contains("restart"),
        "{}",
        response.message
    );
    assert!(
        !log.exists(),
        "docker was called: {}",
        fs::read_to_string(&log).unwrap_or_default()
    );

    // The same host launches normally once the running kernel carries the installed driver.
    fs::remove_file(&soname).unwrap();
    std::os::unix::fs::symlink("libnvidia-ml.so.580.159.03", &soname).unwrap();
    let response = backend
        .execute(&operation)
        .expect("matching driver versions launch");
    assert_eq!(response.code, "started", "{response:?}");
    assert!(fs::read_to_string(&log).unwrap().starts_with("run "));
}
