#[test]
fn quiescence_refuses_when_sparkd_daemon_is_live() {
    let h = Harness::new();
    let staged = h.stage("lab-0.1.0", b"deb-bytes");
    // A synthetic /proc with a live sparkd daemon.
    let proc = h.proc.join("4242");
    fs::create_dir_all(&proc).unwrap();
    std::os::unix::fs::symlink("/usr/lib/spark-runtime/sparkd", proc.join("exe")).unwrap();
    fs::write(
        proc.join("stat"),
        "4242 (sparkd) S 1 4242 4242 0 -1 4194304 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0\n",
    )
    .unwrap();

    let report = h.verify_report(&staged);
    h.runner.ok(Some(0), "", ""); // docker ps quiet
    h.runner.ok(Some(0), &report, ""); // staged verifier
    h.runner.ok(Some(0), "", ""); // systemd stop reports success
    let result = h.director().install("lab-0.1.0");
    assert_refused(result, "UPDATE_NOT_QUIESCENT");
}
