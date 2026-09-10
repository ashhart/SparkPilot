#[tokio::test]
async fn sole_owner_can_rename_and_repeat_the_owner_role_through_the_signed_api() {
    let h = harness();
    let key = fresh_key();
    let presence_key = fresh_key();
    let device = seed_device(&h.state, &key, "owner");
    register_presence_key(&h.state, &device, &presence_key);
    let path = format!("/api/v1/devices/{device}");
    for body in [
        json!({"display_name": "Renamed owner"}),
        json!({"role": "owner"}),
    ] {
        let bytes = serde_json::to_vec(&body).unwrap();
        let mut request = signed(&key, &device, Method::PATCH, &path, &bytes, &fresh_nonce());
        add_presence_proof(&mut request, &presence_key);
        let (status, response) = send(&h.state, request).await;
        assert_eq!(status, StatusCode::OK, "{response}");
    }
    let db = h.state.database.as_ref().unwrap().lock();
    assert_eq!(
        sparkd::store::device_row(&db, &device)
            .unwrap()
            .unwrap()
            .display_name,
        "Renamed owner"
    );
    assert_eq!(sparkd::store::active_owner_count(&db).unwrap(), 1);
}
