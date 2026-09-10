#[test]
fn measured_peaks_and_retry_budget_are_tracked() {
    let conn = migrated_db();
    seed_profile_row(&conn);
    let environment = guard::measurement_environment("vllm@sha256:aaa", "abc123", "2026-09-06.1");

    guard::record_profile_peak(&conn, "llama-8b", "balanced-16k", 55 * GIB, &environment).unwrap();
    guard::record_profile_peak(&conn, "llama-8b", "balanced-16k", 48 * GIB, &environment).unwrap();
    assert_eq!(
        guard::measured_peak(&conn, "llama-8b", "balanced-16k", &environment).unwrap(),
        Some(55 * GIB),
        "high-water mark sticks"
    );

    assert!(guard::can_auto_retry(&conn, "llama-8b", "balanced-16k", 1).unwrap());
    guard::consume_auto_retry(&conn, "llama-8b", "balanced-16k").unwrap();
    assert!(!guard::can_auto_retry(&conn, "llama-8b", "balanced-16k", 1).unwrap());
}
