#[tokio::test]
async fn no_response_field_can_carry_a_container_command_line() {
    // Ensure no inventory field can carry external container command lines or environments that may contain credentials.
    let harness = harness("owner", true);
    *harness.scripted_workloads.lock().unwrap() = Some(a_busy_host());

    let (_, body) = send(
        harness.state,
        signed_get(&harness.client, "/api/v1/workloads"),
    )
    .await;

    let expected: std::collections::BTreeSet<&str> = [
        "workload_id",
        "name",
        "ownership",
        "kind",
        "recognised_engine",
        "management_origin",
        "state",
        "image_reference",
        "published_ports",
        "configuration_state",
        "api_protocol",
        "api_port",
        "served_models",
    ]
    .into_iter()
    .collect();
    for workload in body["workloads"].as_array().unwrap() {
        let actual: std::collections::BTreeSet<&str> = workload
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(
            actual, expected,
            "the observed workload shape must stay the credential-free projection"
        );
    }
    let rendered = serde_json::to_string(&body).unwrap();
    for forbidden in ["command", "env", "labels", "mounts"] {
        assert!(
            !rendered.contains(forbidden),
            "{forbidden} must not appear in a workload inventory: {rendered}"
        );
    }
}
