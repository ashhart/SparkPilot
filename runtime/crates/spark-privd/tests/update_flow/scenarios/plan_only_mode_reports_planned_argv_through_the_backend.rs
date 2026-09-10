#[test]
fn plan_only_mode_reports_planned_argv_through_the_backend() {
    // The docker backend in plan_only mode must answer without executing.
    let backend = spark_privd::backend::DockerBackend::new("docker", true).with_service_uid(euid());
    let response = backend
        .execute(
            &spark_privd::protocol::PrivilegedOperation::InstallRuntimeUpdate {
                request_id: uuid::Uuid::new_v4(),
                release_id: "lab-0.1.0".into(),
            },
        )
        .unwrap();
    assert!(response.accepted);
    assert_eq!(response.code, "planned");
    assert!(response.details.get("argv").is_some());
    let argv = response.details["argv"].as_array().expect("argv array");

    let rendered = format!("{argv:?}");
    assert!(rendered.contains("spark-runtime-update@lab-0.1.0.service"));
    assert!(!rendered.contains("verify-package") && !rendered.contains("dpkg"));
    assert!(
        !rendered.contains("/bin/sh") && !rendered.contains("sh -c"),
        "planned argv must not invoke a shell, got {rendered}"
    );
}
