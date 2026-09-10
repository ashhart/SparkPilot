/// The exact text the Spark produced on 2026-09-04 after an OS update replaced the driver without a reboot.
const DOCKER_PRESTART_MISMATCH_STDERR: &str = "WARNING: Error loading config file: open /root/.docker/config.json: permission denied\n\
docker: Error response from daemon: failed to create task for container: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: error during container init: error running prestart hook #0: exit status 1, stdout: , stderr: Auto-detected mode as 'legacy'\n\
nvidia-container-cli: initialization error: nvml error: driver/library version mismatch\n\
\n\
Run 'docker run --help' for more information";

#[test]
fn a_docker_prestart_driver_mismatch_maps_to_the_typed_code() {
    let root = tempfile::tempdir().unwrap();
    let stderr_file = root.path().join("run-stderr");
    fs::write(&stderr_file, DOCKER_PRESTART_MISMATCH_STDERR).unwrap();
    let (docker, log) = gpu_driver_fake_docker(
        root.path(),
        &format!("  cat '{}' >&2\n  exit 125", stderr_file.display()),
    );
    // No version evidence on this host: only docker's own report proves the mismatch.
    let backend = gpu_driver_backend(
        root.path(),
        &docker,
        &root.path().join("missing-module-version"),
        &root.path().join("missing-lib"),
    );
    let operation = gpu_driver_start_operation(root.path());

    let response = backend
        .execute(&operation)
        .expect("a prestart mismatch is a typed rejection, not a backend error");

    assert!(!response.accepted, "{response:?}");
    assert_eq!(response.code, "GPU_DRIVER_MISMATCH");
    assert!(response.details["kernel_module_version"].is_null());
    assert!(response.details["nvml_library_version"].is_null());
    let raw = response.details["docker_stderr"]
        .as_str()
        .expect("raw docker text is kept as technical detail");
    assert!(raw.contains("nvidia-container-cli: initialization error"));
    assert!(
        !response.message.contains("nvidia-container-cli")
            && response.message.to_lowercase().contains("restart"),
        "{}",
        response.message
    );
    assert!(fs::read_to_string(&log).unwrap().starts_with("run "));
}

#[test]
fn other_docker_run_failures_stay_untyped_backend_failures() {
    let root = tempfile::tempdir().unwrap();
    let (docker, _log) = gpu_driver_fake_docker(
        root.path(),
        "  printf '%s\\n' 'docker: Error response from daemon: No such image: example@sha256:abc' >&2\n  exit 125",
    );
    let backend = gpu_driver_backend(
        root.path(),
        &docker,
        &root.path().join("missing-module-version"),
        &root.path().join("missing-lib"),
    );

    let error = backend
        .execute(&gpu_driver_start_operation(root.path()))
        .expect_err("an unrelated docker failure is still an error");

    assert!(
        matches!(&error, BackendError::Failure(message) if message.starts_with("docker run failed: docker: Error response from daemon: No such image")),
        "{error}"
    );
}
