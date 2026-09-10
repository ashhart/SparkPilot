#[test]
fn event_heartbeat_interval_is_fifteen_seconds() {
    assert_eq!(sparkd::events::HEARTBEAT_INTERVAL, Duration::from_secs(15));
}
