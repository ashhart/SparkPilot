/// Allow explicit reviewed recovery from the unsafe profile state created by emergency stop.
#[test]
fn an_unsafe_profile_can_be_explicitly_re_enabled() {
    let conn = migrated_db();
    seed_profile_row(&conn);
    let environment = guard::measurement_environment("vllm@sha256:aaa", "abc123", "2026-09-06.1");
    guard::record_profile_peak(&conn, "llama-8b", "balanced-16k", 55 * GIB, &environment).unwrap();
    guard::consume_auto_retry(&conn, "llama-8b", "balanced-16k").unwrap();

    guard::mark_profile_unsafe(
        &conn,
        "llama-8b",
        "balanced-16k",
        "MEMORY_PRESSURE_EMERGENCY",
    )
    .unwrap();
    assert!(guard::profile_is_unsafe(&conn, "llama-8b", "balanced-16k").unwrap());
    // Verify the stored measured-peak behavior while the profile remains unsafe.
    assert_eq!(
        guard::measured_peak(&conn, "llama-8b", "balanced-16k", &environment).unwrap(),
        None
    );
    assert!(!guard::can_auto_retry(&conn, "llama-8b", "balanced-16k", 1).unwrap());

    guard::clear_profile_unsafe(&conn, "llama-8b", "balanced-16k").unwrap();

    assert!(!guard::profile_is_unsafe(&conn, "llama-8b", "balanced-16k").unwrap());
    assert_eq!(
        guard::measured_peak(&conn, "llama-8b", "balanced-16k", &environment).unwrap(),
        Some(55 * GIB),
        "re-enabling restores the measurement rather than discarding it"
    );
    assert!(
        guard::can_auto_retry(&conn, "llama-8b", "balanced-16k", 1).unwrap(),
        "the controlled-retry budget is part of the reset"
    );
}
