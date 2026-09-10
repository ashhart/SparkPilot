#[test]
fn usage_aggregates_into_daily_rows_on_the_migrated_schema() {
    let conn = migrated_db();
    let device_id = uuid::Uuid::new_v4();
    sparkd::store::insert_device(
        &conn,
        &device_id,
        "Test Phone",
        "ios",
        b"spki",
        "fp-1",
        "user",
    )
    .unwrap();

    let record = spark_telemetry::UsageRecord::request(
        device_id.to_string(),
        "llama-8b",
        900,
        210,
        Duration::from_millis(62),
        Duration::from_millis(3100),
    );
    spark_telemetry::record_daily(&conn, "2026-08-26", &record).unwrap();
    spark_telemetry::record_daily(&conn, "2026-08-26", &record).unwrap();

    let summary = spark_telemetry::daily_summary(&conn, "2026-08-26").unwrap();
    assert_eq!(summary.len(), 1);
    assert_eq!(summary[0].requests, 2);
    assert_eq!(summary[0].prompt_tokens, 1800);
    assert_eq!(summary[0].generated_tokens, 420);

    // Cumulative latency columns accumulate for derived averages.
    let (ttft_ms, gen_ms): (i64, i64) = conn
        .query_row(
            "SELECT cumulative_ttft_ms, cumulative_generation_ms FROM usage_daily",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(ttft_ms, 124);
    assert_eq!(gen_ms, 6200);
}
