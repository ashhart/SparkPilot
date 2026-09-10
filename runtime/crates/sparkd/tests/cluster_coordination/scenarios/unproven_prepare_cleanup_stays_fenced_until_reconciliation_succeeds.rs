#[test]
fn unproven_prepare_cleanup_stays_fenced_until_reconciliation_succeeds() {
    let (first, second, owner, _, now) = pair();
    let failed = proposal(&first, &second, owner, now);
    *first.link.fail_all_phases.lock().unwrap() = true;

    assert!(matches!(
        first.service.prepare(&failed, owner, now),
        Err(CoordinationError::Link(_))
    ));
    let state: String = first
        .database
        .lock()
        .query_row("SELECT state FROM cluster_transactions", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(state, "rolling_back");

    let competing = proposal(&first, &second, owner, now);
    assert!(matches!(
        first.service.prepare(&competing, owner, now),
        Err(CoordinationError::Conflict(_))
    ));

    *first.link.fail_all_phases.lock().unwrap() = false;
    assert_eq!(
        first
            .service
            .reconcile_expired_transactions_once(now + time::Duration::minutes(6))
            .unwrap(),
        1
    );
    let state: String = first
        .database
        .lock()
        .query_row("SELECT state FROM cluster_transactions", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(state, "rolled_back");

    let fresh_now = now + time::Duration::minutes(6);
    let fresh = proposal(&first, &second, owner, fresh_now);
    first.service.prepare(&fresh, owner, fresh_now).unwrap();
}
