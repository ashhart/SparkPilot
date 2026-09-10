/// P2-1: a broken replay store fails closed rather than disabling the check.
#[test]
fn a_broken_replay_store_fails_closed() {
    let harness = harness();
    let key = fresh_key();
    let device_id = seed_device(&harness.state, &key, "owner");
    let mut conn = harness.state.database.as_ref().unwrap().lock();
    // Drop the table the gate depends on: the claim must error, not succeed.
    conn.execute("DROP TABLE request_nonces", []).unwrap();
    let outcome = sparkd::store::admit_request_nonce(
        &mut conn,
        &device_id,
        b"nonce-digest",
        "2026-09-04T00:00:00Z",
        "2999-01-01T00:00:00Z",
    );
    assert!(
        outcome.is_err(),
        "a storage failure must surface, so the caller can reject"
    );
}
