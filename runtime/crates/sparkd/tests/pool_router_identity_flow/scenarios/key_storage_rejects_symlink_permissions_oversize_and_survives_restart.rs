#[tokio::test]
async fn key_storage_rejects_symlink_permissions_oversize_and_survives_restart() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let source = node().await;
    let original = prepare(&source).await;
    let directory = source.state.config.data_dir.join("router-identity");
    let path = directory.join("request-key.json");
    let bytes = std::fs::read(&path).unwrap();
    let reopened = sparkd::pool_router_identity::RouterIdentityService::new(directory.clone());
    assert_eq!(
        reopened
            .load()
            .unwrap()
            .document(&source.state)
            .unwrap()
            .principal_id
            .to_string(),
        original["principal_id"].as_str().unwrap()
    );
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(reopened.load().is_err());
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    std::fs::write(&path, vec![b'a'; 4097]).unwrap();
    assert!(reopened.load().is_err());
    std::fs::remove_file(&path).unwrap();
    let outside = source.state.config.data_dir.join("untouched-key");
    std::fs::write(&outside, &bytes).unwrap();
    symlink(&outside, &path).unwrap();
    assert!(reopened.load().is_err());
    assert!(
        source
            .post(&format!("{BASE}/router-identity"), &json!({}), true)
            .await
            .0
            .is_client_error()
    );
    assert_eq!(std::fs::read(&outside).unwrap(), bytes);
    source.stop().await;
}
