#[tokio::test]
async fn a_hostile_table_name_cannot_break_the_row_count_query() {
    let (state, client, _directory) = test_state("owner");
    let bundle = export(state.clone(), &client, &[]).await;
    let counts = &section(&bundle, "database.json")["row_counts"];
    assert!(
        counts.get("evil\"; DROP TABLE devices; --").is_some(),
        "the quoted identifier was not counted: {counts}"
    );
    let database = state.database.clone().unwrap();
    let connection = database.lock();
    let devices: i64 = connection
        .query_row("SELECT COUNT(*) FROM devices", [], |row| row.get(0))
        .expect("devices survived the row-count pass");
    assert_eq!(devices, 1);
}
