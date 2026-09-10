#[tokio::test]
async fn every_plan_46_1_category_is_present_with_its_required_fields() {
    let (state, client, _directory) = test_state("owner");
    let bundle = export(state, &client, &[]).await;

    let produced: Vec<&str> = bundle["files"]
        .as_array()
        .unwrap()
        .iter()
        .map(|file| file["path"].as_str().unwrap())
        .collect();
    for required in REQUIRED_SECTIONS {
        assert!(
            produced.contains(required),
            "§46.1 section {required} is missing"
        );
    }

    // Runtime version and configuration.
    let runtime = section(&bundle, "runtime.json");
    assert_eq!(runtime["runtime_version"], "0.1.0");
    assert_eq!(runtime["api_major"], 1);
    assert!(runtime.get("tls").is_some());

    // Include OS, driver, container and hardware facts or explicit unavailable reasons for every required field.
    let host = section(&bundle, "host.json");
    for key in [
        "os",
        "driver",
        "container_runtime",
        "accelerator",
        "storage",
    ] {
        assert!(host.get(key).is_some(), "host.json has no {key}");
    }
    assert!(host.get("unified_memory_total_bytes").is_some());
    assert!(host.get("memory_pressure").is_some());

    // Service status.
    let services = section(&bundle, "services.json");
    for key in ["engine", "memory_guard", "cluster", "remote_access"] {
        assert!(services.get(key).is_some(), "services.json has no {key}");
    }

    // Include bounded runtime, helper, engine and relevant-operation log projections.
    let logs = section(&bundle, "logs.json");
    let sources: Vec<&str> = logs["sources"]
        .as_array()
        .unwrap()
        .iter()
        .map(|source| source["source"].as_str().unwrap())
        .collect();
    assert_eq!(sources, vec!["sparkd", "spark-privd", "engine"]);
    assert!(logs["operation_stages"].get("available").is_some());

    // Memory-pressure timeline.
    assert_eq!(section(&bundle, "memory-pressure.json")["available"], true);

    // Model recipe and profile identifiers and digests.
    let models = section(&bundle, "models.json");
    assert_eq!(models["models"]["available"], true);
    assert_eq!(models["profiles"]["available"], true);

    // Redacted network interfaces.
    assert!(section(&bundle, "network.json").get("available").is_some());

    // Cluster health and validation tests.
    let cluster = section(&bundle, "cluster.json");
    for key in ["cluster", "members", "validation_tests"] {
        assert!(cluster.get(key).is_some(), "cluster.json has no {key}");
    }

    // Schema version and integrity check.
    let database = section(&bundle, "database.json");
    assert!(database["schema_version"].is_number());
    assert_eq!(database["integrity_check"], "ok");
    assert!(database["row_counts"]["devices"].is_number());

    // Audit sequence and chain integrity.
    let audit = section(&bundle, "audit.json");
    assert_eq!(audit["chain_verified"], true);
    assert!(audit.get("highest_sequence").is_some());
}
