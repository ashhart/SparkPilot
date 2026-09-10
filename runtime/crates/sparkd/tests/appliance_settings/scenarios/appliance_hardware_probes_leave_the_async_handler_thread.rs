#[tokio::test(flavor = "current_thread")]
async fn appliance_hardware_probes_leave_the_async_handler_thread() {
    let handler_thread = std::thread::current().id();
    let monitor = Arc::new(ThreadRecordingMonitor::default());
    let (mut state, client, _) = test_state("owner");
    state.telemetry = monitor.clone();

    for path in ["/api/v1/settings", "/api/v1/storage"] {
        let (status, _) = send(
            state.clone(),
            signed_request(&client, Method::GET, path, Value::Null, false),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{path}");
    }

    let probe_threads = monitor.hardware_threads.lock().unwrap().clone();
    assert_eq!(probe_threads.len(), 2);
    assert!(
        probe_threads.iter().all(|thread| *thread != handler_thread),
        "synchronous hardware probes ran on the async handler thread: {probe_threads:?}"
    );
}
