/// Normalize framework refusals without losing headers or altering handler-authored JSON envelopes.
#[tokio::test]
async fn rewriting_a_refusal_keeps_its_headers_and_leaves_json_refusals_alone() {
    let harness = harness();
    let response = router(harness.state.clone())
        .oneshot(signed(
            &harness,
            "POST",
            "/api/v1/settings/telemetry",
            b"not json at all",
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    // Require the API-version header even on framework refusals before handler execution.
    assert!(
        response.headers().contains_key("x-spark-api-version"),
        "the rewritten refusal lost the API version header"
    );
    assert_eq!(
        response
            .headers()
            .get(axum::http::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok()),
        Some("application/json"),
        "a rewritten refusal must be the envelope it claims to be"
    );
    let body = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let envelope: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(envelope["error"]["code"], "REQUEST_INVALID");

    // Preserve the handler's existing JSON error envelope and code.
    let (status, body) = send(
        harness.state.clone(),
        signed(
            &harness,
            "PATCH",
            "/api/v1/devices/00000000-0000-4000-8000-000000000001",
            br#"{"unknown_field":1}"#,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    let envelope: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(envelope["error"]["code"], "PATCH_INVALID");
}
