#[tokio::test]
async fn owner_presence_roles_and_exact_preview_receipts() {
    let f = fixture().await;
    let value = json!({"expected_revision":0,"policy":policy(&f,&f.router)});
    let path = format!("{ROOT}/pools/preview");
    let key = Uuid::new_v4();
    let (s, _) = send(&f, &f.owner, "POST", &path, Some(&value), None, false).await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    let (s, _) = post(&f, &f.router, &path, &value, false).await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    let (s, a) = send(&f, &f.owner, "POST", &path, Some(&value), Some(key), false).await;
    assert_eq!(s, StatusCode::OK, "{a}");
    let (_, b) = send(&f, &f.owner, "POST", &path, Some(&value), Some(key), false).await;
    assert_eq!(a, b);
    let mut changed = value.clone();
    changed["policy"]["display_name"] = json!("Changed");
    let (s, v) = send(
        &f,
        &f.owner,
        "POST",
        &path,
        Some(&changed),
        Some(key),
        false,
    )
    .await;
    assert_eq!(s, StatusCode::CONFLICT, "{v}");
    let apply = json!({"preview_id":a["preview_id"]});
    let apply_path = format!("{ROOT}/pools/apply");
    let key = Uuid::new_v4();
    let (s, _) = send(
        &f,
        &f.owner,
        "POST",
        &apply_path,
        Some(&apply),
        Some(key),
        false,
    )
    .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    let (s, a) = send(
        &f,
        &f.owner,
        "POST",
        &apply_path,
        Some(&apply),
        Some(key),
        true,
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{a}");
    let (s, b) = send(
        &f,
        &f.owner,
        "POST",
        &apply_path,
        Some(&apply),
        Some(key),
        false,
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(a, b);
    close(f).await;
}
