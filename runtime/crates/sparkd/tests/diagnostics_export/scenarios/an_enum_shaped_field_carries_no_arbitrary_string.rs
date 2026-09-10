#[tokio::test]
async fn an_enum_shaped_field_carries_no_arbitrary_string() {
    let (state, client, _directory) = test_state("owner");
    let bundle = export(state, &client, &["host-paths", "network-addresses"]).await;
    assert!(
        !serde_json::to_string(&bundle)
            .unwrap()
            .contains(PLANTED_FREE_TEXT),
        "free text rode out of the node inside a field that looks like an enum"
    );

    // Retain transition time and structure while removing unrecognized enum-shaped text.
    let timeline = section(&bundle, "memory-pressure.json");
    let transition = &timeline["rows"][0];
    assert_eq!(transition["to"], "warning");
    assert_eq!(transition["from"], Value::Null);
    assert_eq!(transition["reason"], Value::Null);
    assert_eq!(transition["available_bytes"], 1_024);

    // And the same for a health column nothing constrains on the way in.
    let remote = &section(&bundle, "services.json")["remote_access"];
    assert_eq!(remote["mode"], "private_overlay");
    assert_eq!(remote["health"], Value::Null);

    // SQLite's integrity report is a verdict, never its prose.
    assert_eq!(section(&bundle, "database.json")["integrity_check"], "ok");
}
