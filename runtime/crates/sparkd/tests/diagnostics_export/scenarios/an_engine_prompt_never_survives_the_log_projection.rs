#[tokio::test]
async fn an_engine_prompt_never_survives_the_log_projection() {
    let (state, client, _directory) = test_state("owner");
    let bundle = export(state, &client, &[]).await;
    let rendered = serde_json::to_string(&bundle).unwrap();
    assert!(
        !rendered.contains("summer we spent at the lake"),
        "an engine log line reached the bundle"
    );
    assert!(
        !rendered.contains("serving request"),
        "log text reached the bundle"
    );

    // Retain log-read volume and severity evidence while removing prompt-bearing content.
    let logs = section(&bundle, "logs.json");
    let engine = logs["sources"]
        .as_array()
        .unwrap()
        .iter()
        .find(|source| source["source"] == "engine")
        .unwrap();
    assert_eq!(engine["available"], true);
    assert_eq!(engine["truncated"], true);
    let records = engine["records"].as_array().unwrap();
    assert!(
        !records.is_empty() && records.len() <= 200,
        "{}",
        records.len()
    );
    for record in records {
        assert_eq!(record["redacted"], true);
        assert!(record.as_object().unwrap().len() <= 3, "{record}");
    }

    // Keep the runtime event identifier while dropping its free-text message.
    let sparkd = logs["sources"]
        .as_array()
        .unwrap()
        .iter()
        .find(|source| source["source"] == "sparkd")
        .unwrap();
    assert_eq!(sparkd["records"][0]["event"], "model.load.started");
    assert!(sparkd["records"][0].get("message").is_none());
}
