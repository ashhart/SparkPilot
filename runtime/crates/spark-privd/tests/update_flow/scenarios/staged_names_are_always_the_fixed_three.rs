#[test]
fn staged_names_are_always_the_fixed_three() {
    // Read and write only fixed release filenames, ignoring unrelated staged files.
    let h = Harness::new();
    let staged = h.stage("lab-0.1.0", b"deb-bytes");
    fs::write(staged.join("evil-extra"), b"junk").unwrap();
    let report = h.verify_report(&staged);
    h.runner.ok(Some(0), "", "");
    h.runner.ok(Some(0), &report, "");
    h.runner.ok(Some(0), "", "");
    h.runner.ok(Some(0), "", "");
    let outcome = h.director().install("lab-0.1.0").unwrap();
    assert!(matches!(outcome, UpdateOutcome::Committed { .. }));
}
