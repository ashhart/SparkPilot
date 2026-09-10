/// Check model identity under the accounting lock so wrong or replaced targets leave counters and activity unchanged.
#[tokio::test]
async fn admission_checks_identity_before_it_counts() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .expect("load operation id")
        .parse()
        .expect("operation uuid");
    let loaded = wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;
    assert_eq!(loaded["state"], "succeeded", "{loaded}");

    let idle_before = h.engine.last_activity();
    for wrong in [
        "",
        "example-32",
        "EXAMPLE-32B",
        "example/model-32b ",
        "mock",
    ] {
        let refusal = h
            .engine
            .admit_request(wrong)
            .err()
            .unwrap_or_else(|| panic!("{wrong:?} was admitted"));
        assert_eq!(refusal.code(), "MODEL_NOT_LOADED", "{wrong:?}");
        assert_eq!(refusal.status(), axum::http::StatusCode::NOT_FOUND);
        assert_eq!(
            h.engine.view().expect("engine loaded").active_requests,
            0,
            "{wrong:?} was counted"
        );
        assert_eq!(
            h.engine.last_activity(),
            idle_before,
            "{wrong:?} moved the idle clock"
        );
    }

    // Both names the engine answers to are admitted, once each.
    for right in ["example-32b", "example/model-32b"] {
        let (ticket, upstream) = h.engine.admit_request(right).expect("admitted");
        assert_eq!(upstream.served_name, "example-32b");
        assert_eq!(
            h.engine.view().expect("engine loaded").active_requests,
            1,
            "{right} did not take exactly one slot"
        );
        drop(ticket);
        assert_eq!(h.engine.view().expect("engine loaded").active_requests, 0);
    }
}
