#[tokio::test]
async fn signed_audience_body_and_nonce_are_required() {
    let f = fixture().await;
    let g = configure(&f, &f.router).await;
    let value = reservation(&f, &g, &chat(false));
    let p = format!("{ROOT}/reservations");
    let mut r = request(
        &f,
        &f.router,
        "POST",
        &p,
        Some(&value),
        Some(Uuid::new_v4()),
        false,
    );
    r.headers_mut().insert(
        "x-spark-node-id",
        Uuid::new_v4().to_string().parse().unwrap(),
    );
    assert!(response(&f, r).await.0.is_client_error());
    let mut r = request(
        &f,
        &f.router,
        "POST",
        &p,
        Some(&value),
        Some(Uuid::new_v4()),
        false,
    );
    *r.body_mut() = Body::from(b"{}".as_slice());
    assert!(response(&f, r).await.0.is_client_error());
    let r = request(
        &f,
        &f.router,
        "POST",
        &p,
        Some(&value),
        Some(Uuid::new_v4()),
        false,
    );
    let headers = r.headers().clone();
    assert_eq!(response(&f, r).await.0, StatusCode::CREATED);
    let mut replay = Request::builder()
        .method("POST")
        .uri(&p)
        .body(Body::from(serde_json::to_vec(&value).unwrap()))
        .unwrap();
    *replay.headers_mut() = headers;
    assert!(response(&f, replay).await.0.is_client_error());
    close(f).await;
}
