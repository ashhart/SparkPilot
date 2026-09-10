/// Equivalent assembled bodies must produce equivalent outcomes regardless of transport chunk boundaries.
#[tokio::test]
async fn the_answer_does_not_depend_on_how_the_body_was_chunked() {
    let harness = harness();
    let mut rng = Lcg::new(ROUTE_SEED ^ 0xC0FFEE);
    let keys = ["model_id", "profile_id", "replace_active", "target"];
    // Compare status and error code because independently generated request ids differ.
    let answer = |status: StatusCode, body: Vec<u8>| {
        let envelope: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
        (
            status,
            envelope["error"]["code"].as_str().unwrap_or("").to_owned(),
        )
    };
    for case in body_corpus(ROUTE_SEED ^ 0xC0FFEE, 64, &keys, "") {
        let (whole_status, whole_body) = send(
            harness.state.clone(),
            signed(
                &harness,
                "POST",
                "/api/v1/inference/load/preview",
                &case.bytes,
            ),
        )
        .await;
        for chunks in fuzz_support::chunkings(&mut rng, &case.bytes) {
            let stream = futures::stream::iter(
                chunks
                    .into_iter()
                    .map(|chunk| Ok::<_, std::io::Error>(axum::body::Bytes::from(chunk))),
            );
            let mut request = signed(
                &harness,
                "POST",
                "/api/v1/inference/load/preview",
                &case.bytes,
            );
            *request.body_mut() = axum::body::Body::from_stream(stream);
            let (status, body) = send(harness.state.clone(), request).await;
            assert_eq!(
                answer(whole_status, whole_body.clone()),
                answer(status, body),
                "{} was answered differently when split into chunks",
                case.label
            );
        }
    }
}
