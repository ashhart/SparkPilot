#[tokio::test]
async fn a_typed_launch_rejection_records_its_code_on_the_operation() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    // What DockerEngineBackend::launch yields for a GPU_DRIVER_MISMATCH helper rejection.
    h.backend.fail_next_launch_with(
        "GPU_DRIVER_MISMATCH: the NVIDIA driver on this Spark was updated to 580.173.02, but the running kernel still has driver 580.159.03 loaded; restart the Spark, then launch the model again [{\"docker_stderr\":\"nvidia-container-cli: initialization error: nvml error: driver/library version mismatch\",\"kernel_module_version\":\"580.159.03\",\"nvml_library_version\":\"580.173.02\"}]",
    );

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("load operation id")
        .parse()
        .expect("operation uuid");
    let terminal = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "failed", "{terminal}");

    let (error_code, detail): (String, String) = {
        let conn = h.state.database.as_ref().expect("db").lock();
        let error_code = conn
            .query_row(
                "SELECT error_code FROM operations WHERE id = ?1",
                [operation_id.to_string()],
                |row| row.get(0),
            )
            .expect("operation error code");
        let payload: String = conn
            .query_row(
                "SELECT payload_json FROM events
                 WHERE operation_id = ?1 AND event_type = 'model.load_failed'",
                [operation_id.to_string()],
                |row| row.get(0),
            )
            .expect("durable model.load_failed event");
        (error_code, payload)
    };
    // The owner-facing code is stable; the prose and the helper's evidence stay with the event.
    assert_eq!(error_code, "GPU_DRIVER_MISMATCH", "{terminal}");
    let payload: Value = serde_json::from_str(&detail).expect("event payload");
    let detail = payload["detail"].as_str().expect("failure detail");
    assert!(detail.contains("restart the Spark"), "{detail}");
    assert!(detail.contains("nvidia-container-cli"), "{detail}");
    assert!(
        h.engine.view().is_none(),
        "failed launch retained an engine instance"
    );
}
