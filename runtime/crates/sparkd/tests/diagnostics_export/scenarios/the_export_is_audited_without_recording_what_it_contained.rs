#[tokio::test]
async fn the_export_is_audited_without_recording_what_it_contained() {
    let (state, client, _directory) = test_state("owner");
    let bundle = export(state.clone(), &client, &["host-paths"]).await;
    let sample = bundle["files"].as_array().unwrap()[0]["content"]
        .as_str()
        .unwrap()
        .to_owned();

    let database = state.database.clone().unwrap();
    let connection = database.lock();
    let mut statement = connection
        .prepare("SELECT action, result, details_json FROM audit_records")
        .unwrap();
    let records: Vec<(String, String, String)> = statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert!(
        records.iter().any(
            |(action, result, _)| action == "diagnostics.export.completed" && result == "accepted"
        ),
        "the export left no audit record: {records:?}"
    );
    for (_, _, details) in &records {
        assert!(
            !details.contains(&sample),
            "an audit record stored the bundle contents"
        );
        assert!(details.len() < 4096, "audit details grew to bundle size");
    }
    // The selection itself is worth recording; the payload is not.
    assert!(
        records
            .iter()
            .any(|(_, _, details)| details.contains("host-paths")),
        "the audit trail does not say which optional categories were exported"
    );
}
