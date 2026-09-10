#[tokio::test]
async fn file_rotation_followed_by_database_failure_never_rotates_twice() {
    let source = node().await;
    let original = prepare(&source).await;
    source.state.database.as_ref().unwrap().lock().execute_batch("CREATE TRIGGER reject_router_receipt BEFORE INSERT ON inference_pool_mutations WHEN NEW.path='/api/v1/inference/router-identity' BEGIN SELECT RAISE(ABORT,'injected receipt failure'); END;").unwrap();
    let request = json!({"expected_key_fingerprint":original["request_key_fingerprint"]});
    let key = Uuid::new_v4();
    let (s, _) = source
        .call(
            "POST",
            &format!("{BASE}/router-identity"),
            Some(&request),
            Some(key),
            true,
        )
        .await;
    assert!(!s.is_success());
    source
        .state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute_batch("DROP TRIGGER reject_router_receipt")
        .unwrap();
    let (s, current) = source
        .call("GET", &format!("{BASE}/router-identity"), None, None, false)
        .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(current["key_generation"], 2);
    assert_ne!(current["principal_id"], original["principal_id"]);
    let (s, v) = source
        .call(
            "POST",
            &format!("{BASE}/router-identity"),
            Some(&request),
            Some(key),
            true,
        )
        .await;
    assert_eq!(s, StatusCode::CONFLICT, "{v}");
    assert_eq!(v["error"]["code"], "POOL_ROUTER_KEY_CHANGED");
    let (_, again) = source
        .call("GET", &format!("{BASE}/router-identity"), None, None, false)
        .await;
    assert_eq!(again, current);
    source.stop().await;
}
