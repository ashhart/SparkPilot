#[tokio::test]
async fn a_guest_reaches_the_chat_gateway_and_nothing_else() {
    let household = household(&evening_policy());
    let forbidden = [
        (Method::GET, "/api/v1/devices"),
        (Method::GET, "/api/v1/models"),
        (Method::GET, "/api/v1/settings"),
        (Method::GET, "/api/v1/telemetry"),
        (Method::GET, "/api/v1/diagnostics"),
        (Method::GET, "/api/v1/remote"),
        (Method::GET, "/api/v1/projects"),
        (Method::GET, "/api/v1/inference/requests"),
        (Method::GET, "/api/v1/inference/active"),
        (Method::GET, "/api/v1/shared-access"),
        (Method::GET, "/api/v1/credentials"),
        (Method::GET, "/api/v1/automations"),
    ];
    for (method, path) in forbidden {
        let (status, body) = send(&household, &household.guest, method, path, Value::Null).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{path} must refuse a guest");
        assert_eq!(error_code(&body), "ROLE_FORBIDDEN", "{path}");
    }

    let posts = [
        ("/api/v1/inference/load", json!({ "model_id": "qwen3-8b" })),
        ("/api/v1/inference/unload", json!({})),
        (
            "/api/v1/inference/analyses",
            json!({ "instruction": "x", "document": "y" }),
        ),
        (
            "/v1/audio/speech",
            json!({ "model": "kokoro", "input": "hello", "voice": "af" }),
        ),
        (
            "/api/v1/pairing/invitations",
            json!({ "role": "user", "expires_in_seconds": 300 }),
        ),
        // The web tools are never a guest's, whatever the owner's internet policy says.
        (
            "/api/v1/web/answer",
            json!({ "model": "qwen3-8b", "question": "what is in the news" }),
        ),
    ];
    for (path, body) in posts {
        let (status, body) = send(&household, &household.guest, Method::POST, path, body).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{path} must refuse a guest");
        assert_eq!(error_code(&body), "ROLE_FORBIDDEN", "{path}");
    }

    // Asking for web access inside an ordinary chat request is refused, never honoured.
    let (status, body) = send(
        &household,
        &household.guest,
        Method::POST,
        "/v1/chat/completions",
        json!({
            "model": "qwen3-8b",
            "messages": [{ "role": "user", "content": "hello" }],
            "metadata": { "spark_web_access": true }
        }),
    )
    .await;
    // BH-42: refused for being a guest rather than for the name of the parameter it happened to use.
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "a guest cannot ask for the web tools"
    );
    assert_eq!(error_code(&body), "ROLE_FORBIDDEN");

    let (status, _) = send(
        &household,
        &household.guest,
        Method::GET,
        "/api/v1/status",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "a guest may still see the node is up");
}
