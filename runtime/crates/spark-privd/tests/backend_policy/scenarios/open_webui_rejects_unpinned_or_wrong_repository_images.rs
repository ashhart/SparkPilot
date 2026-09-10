#[test]
fn open_webui_rejects_unpinned_or_wrong_repository_images() {
    for image in [
        "ghcr.io/open-webui/open-webui:latest",
        "example.invalid/open-webui@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ] {
        let result =
            DockerBackend::new("docker", true).execute(&PrivilegedOperation::InstallOpenWebUi {
                request_id: Uuid::new_v4(),
                image_digest: image.into(),
                admin_email: "owner@sparkpilot.local".into(),
                admin_name: "Spark owner".into(),
                admin_password: SecretString::new("unique-open-webui-password-42"),
                gateway_api_key: SecretString::new("g".repeat(48)),
                port: 18080,
                adopt_existing: false,
            });
        assert!(matches!(result, Err(BackendError::InvalidInput(_))));
    }
}
