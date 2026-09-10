#[test]
fn zombies_do_not_block_quiescence() {
    let h = Harness::new();
    let staged = h.stage("lab-0.1.0", b"deb-bytes");
    let proc = h.proc.join("4242");
    fs::create_dir_all(&proc).unwrap();
    std::os::unix::fs::symlink("/usr/lib/spark-runtime/sparkd", proc.join("exe")).unwrap();
    fs::write(
        proc.join("stat"),
        "4242 (sparkd) Z 1 4242 4242 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0\n",
    )
    .unwrap();
    let report = h.verify_report(&staged);
    h.runner.ok(Some(0), "", "");
    h.runner.ok(Some(0), &report, "");
    h.runner.ok(Some(0), "", "");
    h.runner.ok(Some(0), "", "");
    let outcome = h.director().install("lab-0.1.0").unwrap();
    assert!(matches!(outcome, UpdateOutcome::Committed { .. }));
}
