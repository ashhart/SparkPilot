#[test]
fn a_peak_measured_under_another_engine_is_not_admission_evidence() {
    let conn = migrated_db();
    seed_profile_row(&conn);
    let first = guard::measurement_environment("vllm@sha256:aaa", "abc123", "2026-09-06.1");
    let after_engine_upgrade = guard::measurement_environment("vllm@sha256:bbb", "abc123", "2026-09-06.1");
    let after_revision_change = guard::measurement_environment("vllm@sha256:aaa", "def456", "2026-09-06.1");
    assert_ne!(first, after_engine_upgrade, "the engine image is part of it");
    assert_ne!(first, after_revision_change, "the revision is part of it");
    let after_recipe_restated =
        guard::measurement_environment("vllm@sha256:aaa", "abc123", "2026-09-06.2");
    assert_ne!(first, after_recipe_restated, "a re-signed recipe's profiles are new shapes");

    guard::record_profile_peak(&conn, "llama-8b", "balanced-16k", 55 * GIB, &first).unwrap();
    assert_eq!(
        guard::measured_peak(&conn, "llama-8b", "balanced-16k", &first).unwrap(),
        Some(55 * GIB),
        "the same environment still trusts its own measurement"
    );

    // §32.3: a peak taken under a different engine image says nothing about this one.
    assert_eq!(
        guard::measured_peak(&conn, "llama-8b", "balanced-16k", &after_engine_upgrade).unwrap(),
        None,
        "a stale peak must not be admission evidence"
    );

    // The next load under the new image replaces the peak rather than keeping the old high-water mark.
    guard::record_profile_peak(
        &conn,
        "llama-8b",
        "balanced-16k",
        40 * GIB,
        &after_engine_upgrade,
    )
    .unwrap();
    assert_eq!(
        guard::measured_peak(&conn, "llama-8b", "balanced-16k", &after_engine_upgrade).unwrap(),
        Some(40 * GIB),
        "the new environment starts its own high-water mark"
    );
    assert_eq!(
        guard::measured_peak(&conn, "llama-8b", "balanced-16k", &first).unwrap(),
        None,
        "and the superseded environment's peak is gone, not resurrectable"
    );

    guard::record_profile_peak(
        &conn,
        "llama-8b",
        "balanced-16k",
        44 * GIB,
        &after_engine_upgrade,
    )
    .unwrap();
    assert_eq!(
        guard::measured_peak(&conn, "llama-8b", "balanced-16k", &after_engine_upgrade).unwrap(),
        Some(44 * GIB),
        "within one environment the high-water mark still sticks"
    );
}
