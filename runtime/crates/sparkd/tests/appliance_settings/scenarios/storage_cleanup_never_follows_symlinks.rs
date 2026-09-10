#[tokio::test]
async fn storage_cleanup_never_follows_symlinks() {
    let (state, client, _) = test_state("owner");
    let outside = tempfile::tempdir().unwrap();
    let victim = outside.path().join("victim.part");
    std::fs::write(&victim, b"keep").unwrap();
    std::fs::create_dir_all(&state.storage.downloads).unwrap();
    let linked = state.storage.downloads.join("linked.part");
    let removable = state.storage.downloads.join("remove.part");
    std::os::unix::fs::symlink(&victim, &linked).unwrap();
    std::fs::write(&removable, b"remove").unwrap();
    let (status, _) = send(
        state,
        signed_request(
            &client,
            Method::POST,
            "/api/v1/storage/cleanup",
            json!({
                "partial_downloads": true,
                "unused_blobs": false,
                "stopped_containers": false,
                "unused_images": false
            }),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    for _ in 0..80 {
        if !removable.exists() {
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(!removable.exists());
    assert_eq!(std::fs::read(&victim).unwrap(), b"keep");
    assert!(linked.symlink_metadata().is_ok());
}
