#[test]
fn startup_cleanup_removes_only_stale_vllm_credentials() {
    let root = tempfile::tempdir().unwrap();
    let runtime = root.path().join("run");
    let credentials = runtime.join("credentials");
    std::fs::create_dir_all(&credentials).unwrap();
    let stale = credentials.join(format!("spark-vllm-{}.env", Uuid::new_v4()));
    let unrelated = credentials.join("operator-note");
    std::fs::write(&stale, "VLLM_API_KEY=secret\n").unwrap();
    std::fs::write(&unrelated, "keep\n").unwrap();

    DockerBackend::new("docker", true)
        .with_paths(root.path().join("models"), &runtime)
        .cleanup_stale_credentials()
        .unwrap();

    assert!(!stale.exists());
    assert!(unrelated.exists());
}
