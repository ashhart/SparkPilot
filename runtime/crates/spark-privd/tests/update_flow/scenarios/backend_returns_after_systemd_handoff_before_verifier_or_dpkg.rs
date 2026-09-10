#[test]
fn backend_returns_after_systemd_handoff_before_verifier_or_dpkg() {
    let h = Harness::new();
    h.stage("lab-0.1.0", b"deb-bytes");
    h.runner.ok(Some(0), "", ""); // systemctl --no-block start
    let backend = spark_privd::backend::DockerBackend::new("docker", false)
        .with_update_director(h.director());

    let response = backend
        .execute(
            &spark_privd::protocol::PrivilegedOperation::InstallRuntimeUpdate {
                request_id: uuid::Uuid::new_v4(),
                release_id: "lab-0.1.0".into(),
            },
        )
        .unwrap();

    assert!(response.accepted);
    assert_eq!(response.code, "update.scheduled");
    assert_eq!(
        h.runner.calls(),
        vec![(
            "/usr/bin/systemctl".into(),
            vec![
                "--no-block".into(),
                "start".into(),
                "spark-runtime-update@lab-0.1.0.service".into(),
            ],
        )]
    );
    assert!(
        h.runner.argv_of("/usr/bin/dpkg").is_empty(),
        "the request handler must return before dpkg"
    );
    assert!(
        h.runner
            .argv_of("/usr/lib/spark-runtime/spark-installer")
            .is_empty(),
        "the detached worker owns privileged re-verification"
    );
}
