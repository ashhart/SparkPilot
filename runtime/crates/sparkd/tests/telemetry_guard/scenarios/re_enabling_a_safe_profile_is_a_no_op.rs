/// Treat repeated low-level clearing of an unmarked profile as a no-op.
#[test]
fn re_enabling_a_safe_profile_is_a_no_op() {
    let conn = migrated_db();
    seed_profile_row(&conn);
    guard::clear_profile_unsafe(&conn, "llama-8b", "balanced-16k").unwrap();
    assert!(!guard::profile_is_unsafe(&conn, "llama-8b", "balanced-16k").unwrap());
}
