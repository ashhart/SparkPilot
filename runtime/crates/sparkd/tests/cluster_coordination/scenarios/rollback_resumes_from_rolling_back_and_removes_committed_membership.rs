#[test]
fn rollback_resumes_from_rolling_back_and_removes_committed_membership() {
    let (first, second, owner, _, now) = pair();
    let proposal = proposal(&first, &second, owner, now);
    let grants = vec![
        first.service.prepare(&proposal, owner, now).unwrap(),
        second.service.prepare(&proposal, owner, now).unwrap(),
    ];
    ready_pair(&first, &second, &proposal, &grants, now);
    first
        .database
        .lock()
        .execute(
            "UPDATE cluster_transactions SET state='rolling_back' WHERE transaction_id=?1",
            [proposal.transaction_id.to_string()],
        )
        .unwrap();

    first.service.rollback(&proposal).unwrap();
    let connection = first.database.lock();
    let state: String = connection
        .query_row("SELECT state FROM cluster_transactions", [], |row| {
            row.get(0)
        })
        .unwrap();
    let membership: i64 = connection
        .query_row("SELECT COUNT(*) FROM cluster_state", [], |row| row.get(0))
        .unwrap();
    assert_eq!(state, "rolled_back");
    assert_eq!(membership, 0);
}
