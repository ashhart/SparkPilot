#[tokio::test]
async fn execute_has_exact_digest_terminal_receipt_and_no_persistent_content() {
    let f = fixture().await;
    let g = configure(&f, &f.router).await;
    let body = chat(false);
    let r = reserve(&f, &f.router, &reservation(&f, &g, &body)).await;
    let before = f.backend.completions();
    let mut altered = body.clone();
    altered["max_tokens"] = json!(1);
    let (s, v) = post(&f, &f.router, &path(&r, "/execute"), &altered, false).await;
    assert_eq!(s, StatusCode::CONFLICT);
    assert_eq!(v["error"]["code"], "POOL_REQUEST_DIGEST_MISMATCH");
    assert_eq!(f.backend.completions(), before);
    let key = Uuid::new_v4();
    let (s, v) = send(
        &f,
        &f.router,
        "POST",
        &path(&r, "/execute"),
        Some(&body),
        Some(key),
        false,
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert!(v["choices"].is_array());
    tokio::time::sleep(Duration::from_millis(30)).await;
    let (_, v) = send(&f, &f.router, "GET", &path(&r, ""), None, None, false).await;
    assert_eq!(v["state"], "succeeded");
    assert_eq!(f.backend.completions(), before + 1);
    let (s, _) = send(
        &f,
        &f.router,
        "POST",
        &path(&r, "/execute"),
        Some(&body),
        Some(key),
        false,
    )
    .await;
    assert_eq!(s, StatusCode::CONFLICT);
    assert_eq!(f.backend.completions(), before + 1);
    {
        let conn = f.state.database.as_ref().unwrap().lock();
        let mut stmt = conn
            .prepare("SELECT response_json FROM inference_pool_mutations")
            .unwrap();
        let strings: Vec<String> = stmt
            .query_map([], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert!(strings.iter().all(|s| !s.contains("Unique private prompt")));
        let columns: Vec<String> = conn
            .prepare("PRAGMA table_info(inference_reservations)")
            .unwrap()
            .query_map([], |r| r.get(1))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert!(
            columns
                .iter()
                .all(|v| !["prompt", "body", "response", "messages"].contains(&v.as_str()))
        );
    }
    close(f).await;
}
