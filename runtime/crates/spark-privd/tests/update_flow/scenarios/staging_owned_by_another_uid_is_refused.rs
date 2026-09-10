#[test]
fn staging_owned_by_another_uid_is_refused() {
    let h = Harness::new();
    let _staged = h.stage("lab-0.1.0", b"deb-bytes");
    h.runner.ok(Some(0), "", "");
    // Exercise the ownership mismatch even when the suite runs as root.
    let other_uid = std::os::unix::fs::MetadataExt::uid(&std::fs::metadata(&h.staging).unwrap()) ^ 1;
    let director = RuntimeUpdateDirector::new(other_uid)
        .with_runner(h.runner.clone())
        .with_paths(
            &h.staging,
            &h.state,
            &h.proc,
            &h.trust,
            &h.installer,
            &h.dpkg,
            &h.sparkd,
        );
    let result = director.install("lab-0.1.0");
    assert_refused(result, "UPDATE_STAGING_INVALID");
}
