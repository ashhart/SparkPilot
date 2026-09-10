#[tokio::test]
async fn undispatched_cancel_allows_new_attempt_but_accepted_request_never_does() {
    let f = fixture().await;
    let g = configure(&f, &f.router).await;
    let mut value = reservation(&f, &g, &chat(false));
    let r = reserve(&f, &f.router, &value).await;
    assert_eq!(
        post(&f, &f.router, &path(&r, "/cancel"), &json!({}), false)
            .await
            .0,
        StatusCode::OK
    );
    value["attempt_id"] = json!(Uuid::new_v4());
    let next = reserve(&f, &f.router, &value).await;
    assert_ne!(next["reservation_id"], r["reservation_id"]);
    assert_eq!(
        post(&f, &f.router, &path(&next, "/execute"), &chat(false), false)
            .await
            .0,
        StatusCode::OK
    );
    value["attempt_id"] = json!(Uuid::new_v4());
    let (s, v) = post(
        &f,
        &f.router,
        &format!("{ROOT}/reservations"),
        &value,
        false,
    )
    .await;
    assert_eq!(s, StatusCode::CONFLICT);
    assert_eq!(v["error"]["code"], "POOL_REQUEST_ALREADY_ASSIGNED");
    close(f).await;
}
