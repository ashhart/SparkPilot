#[test]
fn oversized_staged_files_are_refused() {
    let h = Harness::new();
    let staged = h.stage("lab-0.1.0", b"deb-bytes");
    // An oversized manifest: sparse file over the bound.
    let big = staged.join("manifest.json");
    let file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&big)
        .unwrap();
    file.set_len(MAX_MANIFEST_BYTES + 1).unwrap();
    drop(file);
    h.runner.ok(Some(0), "", "");
    let result = h.director().install("lab-0.1.0");
    assert_refused(result, "UPDATE_STAGING_INVALID");
    let _ = (MAX_PACKAGE_BYTES, MAX_SIGNATURE_BYTES);
}
