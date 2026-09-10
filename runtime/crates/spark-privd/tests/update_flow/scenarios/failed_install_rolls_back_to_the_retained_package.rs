#[test]
fn failed_install_rolls_back_to_the_retained_package() {
    let h = Harness::new();
    let staged = h.stage("lab-0.2.0", b"new-deb");
    let report = h.verify_report(&staged);

    // A previous commit left the retained package in place.
    let retained = h.state.join("retained");
    fs::create_dir_all(&retained).unwrap();
    fs::write(retained.join(RETAINED_PACKAGE), b"old-deb").unwrap();
    fs::write(retained.join(RETAINED_MANIFEST), b"{}").unwrap();
    fs::write(retained.join(RETAINED_SIGNATURE), b"sig").unwrap();
    fs::write(h.state.join("current-release-id"), "lab-0.1.0\n").unwrap();

    // Script an install health failure followed by successful retained-package verification and installation.
    h.runner.ok(Some(0), "", "");
    h.runner.ok(Some(0), &report, "");
    h.runner.ok(Some(0), "", "");
    h.runner.ok(Some(1), "", "post-install health gate failed");
    let retained_report = serde_json::json!({
        "name": "package", "size": 7, "sha256": sha256(b"old-deb"),
        "signature_key_id": "test", "trust_root_source": "installed",
    })
    .to_string();
    h.runner.ok(Some(0), &retained_report, "");
    h.runner.ok(Some(0), "", "");

    let outcome = h.director().install("lab-0.2.0").unwrap();
    assert!(outcome.accepted());
    match &outcome {
        UpdateOutcome::RolledBack {
            release_id,
            rolled_back_to,
        } => {
            assert_eq!(release_id, "lab-0.2.0");
            assert_eq!(rolled_back_to, "lab-0.1.0");
        }
        other => panic!("expected rollback, got {other:?}"),
    }

    // Require re-verification and installation of the retained package during rollback.
    let dpkg = h.runner.argv_of("/usr/bin/dpkg");
    assert_eq!(dpkg.len(), 2, "failed install then rollback install");
    assert!(
        dpkg[1][1].ends_with("current.deb"),
        "rollback must install the retained current package, got {dpkg:?}"
    );
    let verifier = h.runner.argv_of("/usr/lib/spark-runtime/spark-installer");
    assert_eq!(verifier.len(), 2, "staged verify then retained verify");
    let retained_verify = verifier[1].join(" ");
    assert!(
        retained_verify.contains("retained/current.deb")
            && retained_verify.contains("retained/current.manifest.json")
            && retained_verify.contains("retained/current.deb.sig"),
        "retained re-verification must target the retained file names, got {retained_verify}"
    );
    // The failed up-version was never committed.
    assert_eq!(
        fs::read_to_string(h.state.join("current-release-id"))
            .unwrap()
            .trim(),
        "lab-0.1.0"
    );
}
