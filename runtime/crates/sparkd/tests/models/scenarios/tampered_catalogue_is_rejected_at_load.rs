#[tokio::test]
async fn tampered_catalogue_is_rejected_at_load() {
    let dir = tempfile::tempdir().unwrap();
    let (catalogue_path, root_path) = write_signed_catalogue(dir.path());
    // Flip a byte in the stored catalogue.
    let mut bytes = std::fs::read(&catalogue_path).unwrap();
    let mid = bytes.len() / 2;
    bytes[mid] ^= 0xff;
    let tampered = dir.path().join("tampered.json");
    std::fs::write(&tampered, bytes).unwrap();
    let result = ModelInventory::from_catalogue(Some(&tampered), Some(&root_path), None, false);
    assert!(result.is_err(), "tampered catalogue must not load");
}
