#[test]
fn on_darwin_or_linux_proc_scan_ignores_non_numeric_entries() {
    let h = Harness::new();
    fs::create_dir_all(h.proc.join("not-a-pid")).unwrap();
    fs::create_dir_all(&h.proc).unwrap();
    let staged = h.stage("lab-0.1.0", b"deb-bytes");
    let report = h.verify_report(&staged);
    h.runner.ok(Some(0), "", "");
    h.runner.ok(Some(0), &report, "");
    h.runner.ok(Some(0), "", "");
    h.runner.ok(Some(0), "", "");
    let outcome = h.director().install("lab-0.1.0").unwrap();
    assert!(matches!(outcome, UpdateOutcome::Committed { .. }));
}
