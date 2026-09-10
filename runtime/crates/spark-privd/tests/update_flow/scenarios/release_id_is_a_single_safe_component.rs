#[test]
fn release_id_is_a_single_safe_component() {
    for bad in [
        "",
        "a",
        "..",
        ".",
        "0abc",
        "A-b",
        "a/b",
        "a b",
        "a\nb",
        "a\\b",
        "a:b",
        &"a".repeat(129),
    ] {
        let result = validate_release_id(bad);
        assert!(result.is_err(), "{bad:?} must be refused");
    }
    for good in [
        "lab-0.1.0",
        "dev-1.2.3_rc.1",
        "stable-9.9.9",
        "lab-0.1.0-dev.1",
    ] {
        validate_release_id(good).expect("valid release id");
    }
}
