#[test]
fn open_webui_install_plan_is_pinned_loopback_only_and_keeps_secrets_out_of_argv() {
    let password = "unique-open-webui-password-42";
    let gateway_key = "g".repeat(48);
    let response = DockerBackend::new("docker", true)
        .execute(&PrivilegedOperation::InstallOpenWebUi {
            request_id: Uuid::new_v4(),
            image_digest: format!("ghcr.io/open-webui/open-webui@sha256:{}", "a".repeat(64)),
            admin_email: "owner@sparkpilot.local".into(),
            admin_name: "Spark owner".into(),
            admin_password: SecretString::new(password),
            gateway_api_key: SecretString::new(gateway_key.clone()),
            port: 18080,
            adopt_existing: false,
        })
        .expect("valid signed-recipe-derived service plan");

    assert_eq!(response.code, "planned");
    let argv = response.details["argv"].as_array().unwrap();
    let rendered = serde_json::to_string(argv).unwrap();
    assert!(rendered.contains("--network=host"));
    assert!(rendered.contains("HOST=127.0.0.1"));
    assert!(rendered.contains("--read-only"));
    assert!(rendered.contains("--cap-drop=ALL"));
    assert!(!rendered.contains(password));
    assert!(!rendered.contains(&gateway_key));
}
