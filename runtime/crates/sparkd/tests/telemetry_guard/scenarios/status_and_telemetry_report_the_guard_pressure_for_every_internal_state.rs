#[tokio::test]
async fn status_and_telemetry_report_the_guard_pressure_for_every_internal_state() {
    for (available_gib, expected) in [
        (60u64, "normal"),
        (15, "warning"),
        (12, "critical"), // draining projects to critical
        (8, "critical"),
        (5, "emergency"),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let mut identity = FileIdentityStore::new(dir.path().join("identity"))
            .load_or_create("test-node")
            .unwrap();
        identity.public.node_id = SIGNING_NODE_ID;
        let conn = migrated_db();
        let client = TestClient {
            key: {
                loop {
                    let mut scalar = [0u8; 32];
                    rand::rng().fill_bytes(&mut scalar);
                    if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&scalar) {
                        break key;
                    }
                }
            },
            device_id: uuid::Uuid::new_v4(),
        };
        let spki = client
            .key
            .verifying_key()
            .to_public_key_der()
            .unwrap()
            .as_bytes()
            .to_vec();
        sparkd::store::insert_device(
            &conn,
            &client.device_id,
            "test client",
            "macos",
            &spki,
            &sha256_hex(&spki),
            "owner",
        )
        .unwrap();

        let source = Arc::new(ScriptedSource::new(vec![sample(available_gib)]));
        // Use a resident engine to sustain Emergency; with no engine the verified stop correctly moves to Recovering.
        let guard = MemoryGuardService::without_database_for_testing(
            MemoryPolicy::default(),
            source.clone(),
            Arc::new(RunningEngine),
            EventBus::new(),
        );
        // Hold each reading past escalation dwell to establish the intended internal state.
        for second in 0..8u64 {
            source.queue(sample(available_gib));
            guard.tick(Duration::from_secs(second), "node-1");
        }

        let config = RuntimeConfig {
            api_major: 1,
            runtime_version: "0.1.0".to_owned(),
            listen: "127.0.0.1:0".parse().unwrap(),
            node_name: "test-node".to_owned(),
            data_dir: dir.path().to_path_buf(),
            advertise: false,
            tls: false,
        };
        let state = AppState::new(
            config,
            identity,
            Arc::new(spark_telemetry::FakeSystemMonitor),
            Some(conn),
        )
        .with_guard(Arc::new(guard));

        let response = router(state.clone())
            .oneshot(signed_get(&client, "/api/v1/status"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            value["system"]["memory_pressure"], expected,
            "available {available_gib} GiB must project to {expected}"
        );
        // Report unknown thermal state for samples without temperature, never nominal.
        assert_eq!(
            value["system"]["thermal_state"], "unknown",
            "a node with no temperature reading must not report a thermal rung"
        );
        // §41.5.2.1: the thresholds travel with the rung so no client re-derives a heat verdict.
        assert_eq!(value["system"]["thermal_warning_celsius"], 75.0);
        assert_eq!(value["system"]["thermal_hot_celsius"], 84.0);
        assert_eq!(value["system"]["thermal_critical_celsius"], 90.0);

        let response = router(state)
            .oneshot(signed_get(&client, "/api/v1/telemetry"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            value["system"]["memory_pressure"], expected,
            "live telemetry at {available_gib} GiB must use the guard's {expected} projection"
        );
        // Status and telemetry must not disagree about heat.
        assert_eq!(value["system"]["thermal_state"], "unknown");
        assert_eq!(value["system"]["thermal_warning_celsius"], 75.0);
        assert_eq!(value["system"]["thermal_hot_celsius"], 84.0);
        assert_eq!(value["system"]["thermal_critical_celsius"], 90.0);
    }
}
