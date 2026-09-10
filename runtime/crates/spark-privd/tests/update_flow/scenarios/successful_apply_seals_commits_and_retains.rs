#[test]
fn successful_apply_seals_commits_and_retains() {
    let h = Harness::new();
    let staged = h.stage("lab-0.1.0", b"deb-bytes");
    let report = h.verify_report(&staged);
    // docker ps (quiet), verifier ok, systemd stop ok, dpkg ok.
    h.runner.ok(Some(0), "", "");
    h.runner.ok(Some(0), &report, "");
    h.runner.ok(Some(0), "", "");
    h.runner.ok(Some(0), "", "");

    let outcome = h.director().install("lab-0.1.0").unwrap();
    assert!(matches!(outcome, UpdateOutcome::Committed { .. }));
    assert_eq!(outcome.code(), "update.committed");
    assert!(outcome.accepted());

    // Exact argv, no shell: verifier, then dpkg against the SEALED copy.
    let dpkg = h.runner.argv_of("/usr/bin/dpkg");
    assert_eq!(dpkg.len(), 1);
    let sealed = dpkg[0][1].clone();
    assert!(
        sealed.ends_with("/state/apply/lab-0.1.0/package.deb"),
        "dpkg must target the root-owned sealed copy, got {sealed}"
    );
    assert!(
        !sealed.contains("updates/"),
        "sealed path is not in staging"
    );

    // Require commit and retention evidence to preserve staged bytes.
    assert_eq!(
        fs::read_to_string(h.state.join("current-release-id"))
            .unwrap()
            .trim(),
        "lab-0.1.0"
    );
    assert_eq!(
        fs::read(h.state.join("retained").join(RETAINED_PACKAGE)).unwrap(),
        b"deb-bytes"
    );
    assert_eq!(
        fs::read(h.state.join("retained").join(RETAINED_MANIFEST)).unwrap(),
        b"{}"
    );
    assert!(h.state.join("retained").join(RETAINED_SIGNATURE).is_file());
    // The sealed copy is byte-identical to the staged package.
    assert_eq!(
        fs::read(&sealed).unwrap(),
        b"deb-bytes",
        "sealed bytes must equal the verified staged bytes"
    );
}
