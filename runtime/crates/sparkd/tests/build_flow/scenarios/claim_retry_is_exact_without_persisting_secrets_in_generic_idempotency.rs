#[test]
fn claim_retry_is_exact_without_persisting_secrets_in_generic_idempotency() {
    let harness = harness();
    let worker = Uuid::new_v4();
    harness
        .service
        .register_worker(
            "Owner",
            &harness.owner,
            "18.0",
            "macOS 27",
            &capabilities(1),
            Some(worker),
        )
        .unwrap();
    submit(&harness, &BuildRequirements::default());
    let request_id = Uuid::new_v4();
    let first = harness
        .service
        .claim_next(&worker, &harness.owner, &request_id)
        .unwrap()
        .unwrap();
    let replay = harness
        .service
        .claim_next(&worker, &harness.owner, &request_id)
        .unwrap()
        .unwrap();
    assert_eq!(first, replay);
    let conn = harness.service.projects.db.lock();
    let records: i64 = conn
        .query_row("SELECT COUNT(*) FROM idempotency_records", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(records, 0);
}
