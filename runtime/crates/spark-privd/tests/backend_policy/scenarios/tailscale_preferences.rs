fn overlay_operation(operation: &str, fields: serde_json::Value) -> PrivilegedOperation {
    let mut value = fields;
    value["operation"] = serde_json::json!(operation);
    value["request_id"] = serde_json::json!(Uuid::new_v4());
    serde_json::from_value(value).expect("the helper accepts the typed preference operation")
}

#[test]
fn tailscale_preferences_return_only_the_two_public_settings() {
    let (paths, _guard) = tailscale_test_paths(true, true);
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), r#"{"WantRunning":true,"CorpDNS":false,"RouteAll":true,"Persist":{"PrivateNodeKey":"private-test-value"}}"#, "");
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_tailscale_paths(paths);
    let response = backend.execute(&overlay_operation("tailscale_preferences", serde_json::json!({}))).unwrap();
    assert_eq!(response.details, serde_json::json!({"provider":"tailscale","enabled":true,"accept_dns":false}));
    assert!(!format!("{response:?}").contains("private-test-value"));
}

#[test]
fn tailscale_dns_changes_only_dns_and_verifies_the_result() {
    let (paths, _guard) = tailscale_test_paths(true, true);
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), r#"{"WantRunning":true,"CorpDNS":false}"#, "");
    runner.ok(Some(0), "", "");
    runner.ok(Some(0), r#"{"WantRunning":true,"CorpDNS":true}"#, "");
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner.clone())
        .with_tailscale_paths(paths);
    let response = backend.execute(&overlay_operation("configure_tailscale", serde_json::json!({"accept_dns":true}))).unwrap();
    assert!(response.accepted);
    assert_eq!(response.details["accept_dns"], true);
    let calls = runner.calls();
    assert_eq!(calls[1], ("/usr/bin/timeout".into(), ["--kill-after=2s", "20s", TAILSCALE_BIN, "set", "--accept-dns=true"].map(String::from).to_vec()));
    assert_eq!(calls.len(), 3);
}

#[test]
fn tailscale_pause_keeps_membership_and_resume_keeps_saved_preferences() {
    for enabled in [false, true] {
        let (paths, _guard) = tailscale_test_paths(true, true);
        let runner = Arc::new(RecordingRunner::new());
        runner.ok(Some(0), &format!(r#"{{"WantRunning":{},"CorpDNS":true}}"#, !enabled), "");
        if enabled { runner.ok(Some(0), r#"{"BackendState":"Stopped"}"#, ""); }
        runner.ok(Some(0), "", "");
        runner.ok(Some(0), &format!(r#"{{"WantRunning":{enabled},"CorpDNS":true}}"#), "");
        let backend = DockerBackend::new("docker", false)
            .with_appliance_command_runner(runner.clone())
            .with_tailscale_paths(paths);
        let response = backend.execute(&overlay_operation("configure_tailscale", serde_json::json!({"enabled":enabled}))).unwrap();
        assert_eq!(response.details["enabled"], enabled);
        assert_eq!(response.details["accept_dns"], true);
        let calls = runner.calls();
        let mutation = &calls[if enabled { 2 } else { 1 }];
        assert_eq!(mutation.1, ["--kill-after=2s", "20s", TAILSCALE_BIN, if enabled { "up" } else { "down" }].map(String::from).to_vec());
    }
}

#[test]
fn tailscale_preferences_never_guess_missing_values_or_echo_cli_secrets() {
    for (code, output) in [(0, r#"{"WantRunning":true}"#), (0, r#"{"CorpDNS":"private-test-value"}"#), (1, "private-test-value")] {
        let (paths, _guard) = tailscale_test_paths(true, true);
        let runner = Arc::new(RecordingRunner::new());
        runner.ok(Some(code), output, "private-test-value");
        let backend = DockerBackend::new("docker", false)
            .with_appliance_command_runner(runner)
            .with_tailscale_paths(paths);
        let error = backend.execute(&overlay_operation("tailscale_preferences", serde_json::json!({}))).unwrap_err();
        assert!(!error.to_string().contains("private-test-value"));
    }
}

#[test]
fn tailscale_configuration_rejects_empty_combined_and_unavailable_changes() {
    for fields in [serde_json::json!({}), serde_json::json!({"enabled":true,"accept_dns":true})] {
        let (paths, _guard) = tailscale_test_paths(true, true);
        let runner = Arc::new(RecordingRunner::new());
        let backend = DockerBackend::new("docker", false)
            .with_appliance_command_runner(runner.clone())
            .with_tailscale_paths(paths);
        assert!(backend.execute(&overlay_operation("configure_tailscale", fields)).is_err());
        assert!(runner.calls().is_empty());
    }
}

#[test]
fn tailscale_configuration_does_not_claim_success_when_the_change_did_not_apply() {
    let (paths, _guard) = tailscale_test_paths(true, true);
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), r#"{"WantRunning":true,"CorpDNS":false}"#, "");
    runner.ok(Some(0), "", "");
    runner.ok(Some(0), r#"{"WantRunning":true,"CorpDNS":false}"#, "");
    let backend = DockerBackend::new("docker", false)
        .with_appliance_command_runner(runner)
        .with_tailscale_paths(paths);
    assert!(backend.execute(&overlay_operation("configure_tailscale", serde_json::json!({"accept_dns":true}))).is_err());
}
