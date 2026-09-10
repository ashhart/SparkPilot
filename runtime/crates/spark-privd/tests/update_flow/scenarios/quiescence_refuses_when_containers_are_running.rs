#[test]
fn quiescence_refuses_when_containers_are_running() {
    let h = Harness::new();
    let _staged = h.stage("lab-0.1.0", b"deb-bytes");
    h.runner.ok(Some(0), "0123456789ab\n", ""); // docker ps lists a container

    let result = h.director().install("lab-0.1.0");
    assert_refused(result, "UPDATE_NOT_QUIESCENT");
    assert!(h.runner.argv_of("/usr/bin/dpkg").is_empty());
    assert!(
        h.runner
            .argv_of("/usr/lib/spark-runtime/spark-installer")
            .is_empty()
    );
}
