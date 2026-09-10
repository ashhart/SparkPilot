use super::*;

fn file(size_bytes: u64) -> RemoteFile {
    RemoteFile {
        relative_path: "model.safetensors".into(),
        size_bytes,
        sha256: "0".repeat(64),
    }
}

#[test]
fn total_bytes_saturates_instead_of_wrapping() {
    // Saturate hostile size totals so overflow cannot bypass disk-reserve preflight.
    let files = [file(u64::MAX), file(u64::MAX), file(1)];
    assert_eq!(total_bytes(&files), u64::MAX);
}

#[test]
fn total_bytes_sums_normal_inputs() {
    assert_eq!(total_bytes(&[file(10), file(20), file(3)]), 33);
}

#[test]
fn preview_bounds_weight_hashing_but_install_still_verifies_large_staged_files() {
    let root = tempfile::tempdir().unwrap();
    let recipe = spark_models::recipe::fixture::RecipeFixture::example();
    let directory = work_dir(root.path(), &recipe).unwrap();
    std::fs::create_dir_all(&directory).unwrap();
    let path = directory.join("model.safetensors");
    let size = 33 * 1024 * 1024;
    std::fs::File::create(&path).unwrap().set_len(size).unwrap();
    let mut staged = file(size);
    staged.sha256 = sha256_file(&path).unwrap();
    assert_eq!(
        preview_reusable_bytes(root.path(), &recipe, &[staged.clone()]).unwrap(),
        0
    );
    assert_eq!(
        verified_reusable_bytes(root.path(), &recipe, &[staged.clone()]).unwrap(),
        size
    );
    staged.sha256 = "0".repeat(64);
    assert_eq!(
        verified_reusable_bytes(root.path(), &recipe, &[staged]).unwrap(),
        0
    );
}
