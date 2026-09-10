use super::*;

fn database() -> Connection {
    let mut conn = Connection::open_in_memory().expect("in-memory database");
    crate::migration::migrate(&mut conn).expect("migrate");
    conn
}

/// A node-wide ceiling must bound six-digit guessing across many source addresses during the fifteen-minute lifetime (M2).
#[test]
fn a_swept_code_space_stops_being_answered() {
    let conn = database();
    // Wrong codes, from any number of sources. The node counts them all.
    for attempt in 0..MAX_FAILED_JOIN_CODES {
        let error = redeem_join_code(&conn, "000000").expect_err("no such invitation");
        assert!(
            matches!(error, PairingError::InvalidJoinCode),
            "attempt {attempt} should still be answered: {error:?}"
        );
    }
    let error = redeem_join_code(&conn, "000000").expect_err("ceiling reached");
    assert!(
        matches!(error, PairingError::TooManyJoinCodeAttempts { .. }),
        "the sweep must stop being answered: {error:?}"
    );
}

/// Reject malformed codes before counting so arbitrary invalid input cannot consume the legitimate pairing budget.
#[test]
fn a_malformed_code_does_not_consume_the_ceiling() {
    let conn = database();
    for _ in 0..(MAX_FAILED_JOIN_CODES * 2) {
        assert!(matches!(
            redeem_join_code(&conn, "not-a-code").expect_err("malformed"),
            PairingError::InvalidJoinCode
        ));
    }
    let counted: i64 = conn
        .query_row("SELECT COUNT(*) FROM join_code_attempts", [], |row| {
            row.get(0)
        })
        .expect("count");
    assert_eq!(counted, 0, "a malformed code is not an attempt at a code");
}

/// A locked node says how long to wait so the app can show a bounded wait rather than a bare refusal (L-1).
#[test]
fn a_locked_node_reports_how_long_to_wait() {
    let conn = database();
    for _ in 0..MAX_FAILED_JOIN_CODES {
        let _ = redeem_join_code(&conn, "000000");
    }
    assert_eq!(
        join_code_failures_in_window(&conn).expect("count"),
        MAX_FAILED_JOIN_CODES
    );
    match redeem_join_code(&conn, "000000").expect_err("locked") {
        PairingError::TooManyJoinCodeAttempts {
            retry_after_seconds,
        } => assert!(
            (1..=JOIN_CODE_FAILURE_WINDOW_MINUTES as u64 * 60).contains(&retry_after_seconds),
            "{retry_after_seconds}"
        ),
        other => panic!("unexpected {other:?}"),
    }
}
