#[tokio::test]
async fn kokoro_lifecycle_requires_presence_and_speech_requires_inference_authority() {
    for action in ["install", "update", "enable", "disable", "remove"] {
        let path = format!("/api/v1/services/kokoro/{action}");
        let (state, owner, observed) = test_state("owner");
        let (status, body) = send(
            state.clone(),
            signed_request(&owner, Method::POST, &path, Value::Null, false),
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{path}: {body}");
        assert_eq!(body["error"]["code"], "USER_PRESENCE_REQUIRED");
        assert!(observed.lock().unwrap().is_empty());
        let (status, _) = send(
            state,
            signed_request(&owner, Method::POST, &path, Value::Null, true),
        )
        .await;
        assert_eq!(status, StatusCode::ACCEPTED, "{path}");
        wait_for(&observed, &format!("{action}_kokoro"));
        let (state, observer, observed) = test_state("observer");
        let (status, _) = send(
            state,
            signed_request(&observer, Method::POST, &path, Value::Null, true),
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert!(observed.lock().unwrap().is_empty());
    }
    let request = json!({"model":"kokoro","input":"hello","voice":"af_heart","response_format":"wav","speed":1.0});
    let (state, observer, _) = test_state("observer");
    let (status, _) = send(
        state.clone(),
        signed_request(
            &observer,
            Method::POST,
            "/v1/audio/speech",
            request.clone(),
            false,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = send(
        state,
        Request::builder()
            .method("POST")
            .uri("/v1/audio/speech")
            .header("content-type", "application/json")
            .body(axum::body::Body::from(request.to_string()))
            .unwrap(),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (state, owner, _) = test_state("owner");
    let mut invalid = request;
    invalid["voice"] = json!("../../foreign.pt");
    let (status, body) = send(
        state,
        signed_request(&owner, Method::POST, "/v1/audio/speech", invalid, false),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(body["error"]["code"], "INVALID_SPEECH_REQUEST");
}
