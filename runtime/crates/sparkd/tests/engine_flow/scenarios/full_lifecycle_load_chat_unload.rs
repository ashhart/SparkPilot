#[tokio::test]
async fn full_lifecycle_load_chat_unload() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    // Load is accepted only for an installed model after admission.
    let load_operation_id: uuid::Uuid =
        load_model(&client, addr, &key, &device_id, None).await["id"]
            .as_str()
            .and_then(|s| uuid::Uuid::parse_str(s).ok())
            .expect("load operation id");
    let terminal = wait_terminal(&h.state, load_operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");

    // Active engine state reflects model and readiness (idle, no requests).
    let (status, active) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        "/api/v1/inference/active",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{active}");
    assert_eq!(active["state"].as_str().unwrap_or(""), "idle", "{active}");
    assert_eq!(active["model_id"], "example/model-32b");
    assert_eq!(active["profile_id"], "balanced-16k");
    assert_eq!(active["context_length"], 16384);

    // OpenAI-compatible model list resolves to the served name.
    let (status, models) =
        signed_json(&client, addr, &key, &device_id, "GET", "/v1/models", None).await;
    assert_eq!(status, reqwest::StatusCode::OK, "{models}");
    assert_eq!(models["data"][0]["id"], "example-32b");

    // Non-streaming completion through the proxy (usage counted).
    let (status, completion) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/v1/chat/completions",
        Some(json!({
            "model": "example-32b",
            "messages": [{"role": "user", "content": "hi"}],
            "max_tokens": 16,
            "stream": false,
        })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{completion}");
    assert_eq!(completion["object"], "chat.completion");
    assert!(
        completion["choices"][0]["message"]["content"]
            .as_str()
            .is_some_and(|c| !c.is_empty())
    );
    assert!(completion["usage"]["total_tokens"].as_u64().unwrap_or(0) > 0);

    // Accept the active model's signed catalogue identity and translate it to the engine wire name.
    let (status, completion) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/v1/chat/completions",
        Some(json!({
            "model": "example/model-32b",
            "messages": [{"role": "user", "content": "catalogue alias"}],
            "max_tokens": 16,
            "stream": false,
        })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{completion}");
    assert_eq!(completion["model"], "example-32b", "{completion}");

    // Give Responses requests the same model identity, signature, allowlist and usage rules as chat completions.
    let (status, response) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/v1/responses",
        Some(json!({
            "model": "example/model-32b",
            "input": "hello from Codex",
            "stream": false,
            "unsafe_engine_knob": "discard me",
        })),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{response}");
    assert_eq!(response["object"], "response");
    assert_eq!(response["model"], "example-32b");
    assert_eq!(response["usage"]["input_tokens"], 12);

    let response_body = serde_json::to_vec(&json!({
        "model": "example-32b",
        "input": "stream from Codex",
        "stream": true,
    }))
    .unwrap();
    let (headers, bytes) = signed_parts(&key, &device_id, "POST", "/v1/responses", &response_body);
    let mut response_builder = client
        .post(format!("http://{addr}/v1/responses"))
        .body(bytes);
    for (name, value) in headers {
        response_builder = response_builder.header(name, value);
    }
    let responses_stream = response_builder.send().await.expect("responses stream");
    assert_eq!(responses_stream.status(), reqwest::StatusCode::OK);
    let responses_text = responses_stream.text().await.expect("responses text");
    assert!(responses_text.contains("response.output_text.delta"));
    assert!(responses_text.contains("response.completed"));

    // Streaming completion arrives as SSE frames ending in [DONE].
    let (_status, _stream) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/v1/chat/completions",
        Some(json!({
            "model": "example-32b",
            "messages": [{"role": "user", "content": "stream me"}],
            "stream": true,
            "stream_options": { "include_usage": true },
        })),
    )
    .await;
    // Streaming responses are SSE text, not JSON; read the raw body.
    let (headers, bytes) = signed_parts(
        &key,
        &device_id,
        "POST",
        "/v1/chat/completions",
        &serde_json::to_vec(&json!({
            "model": "example-32b",
            "messages": [{"role": "user", "content": "stream me"}],
            "stream": true,
            "stream_options": { "include_usage": true },
        }))
        .unwrap(),
    );
    let mut builder = client
        .post(format!("http://{addr}/v1/chat/completions"))
        .body(bytes);
    for (name, value) in headers {
        builder = builder.header(name, value);
    }
    let stream_response = builder.send().await.expect("stream request");
    assert_eq!(stream_response.status(), reqwest::StatusCode::OK);
    let text = stream_response.text().await.expect("stream text");
    assert!(text.contains("[DONE]"), "{text}");
    assert!(text.contains("chat.completion.chunk"), "{text}");

    // The engine served; metrics were recorded from the real request.
    let (_, active) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        "/api/v1/inference/active",
        None,
    )
    .await;
    assert!(active["tokens_per_second"].is_number(), "{active}");

    // Unload drains, stops the stub and verifies memory recovery.
    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/unload",
        Some(json!({})),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{body}");
    let unload_operation_id: uuid::Uuid = body["id"]
        .as_str()
        .and_then(|s| uuid::Uuid::parse_str(s).ok())
        .expect("unload operation id");
    let terminal = wait_terminal(&h.state, unload_operation_id, Duration::from_secs(10)).await;
    assert_eq!(terminal["state"], "succeeded", "{terminal}");

    let (status, active) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        "/api/v1/inference/active",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{active}");
    assert_eq!(active["state"], "unloaded");
    assert!(
        h.engine.internal_port().is_none(),
        "engine cleared after unload"
    );

    let audit = {
        let connection = h.state.database.as_ref().unwrap().lock();
        let mut statement = connection
            .prepare(
                "SELECT action, result, resource, operation_id, details_json
                   FROM audit_records
                  WHERE action IN ('model.load.preview','model.load',
                                   'model.unload.preview','model.unload')
                  ORDER BY sequence",
            )
            .unwrap();
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, String>(4)?,
                ))
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap()
    };
    assert_eq!(
        audit.iter().map(|row| row.0.as_str()).collect::<Vec<_>>(),
        [
            "model.load.preview",
            "model.load",
            "model.load",
            "model.unload.preview",
            "model.unload",
            "model.unload",
        ]
    );
    assert_eq!(
        audit.iter().map(|row| row.1.as_str()).collect::<Vec<_>>(),
        [
            "accepted",
            "accepted",
            "succeeded",
            "accepted",
            "accepted",
            "succeeded",
        ]
    );
    let load_operation_id = load_operation_id.to_string();
    let unload_operation_id = unload_operation_id.to_string();
    assert_eq!(audit[1].2.as_deref(), Some("model/example/model-32b"));
    assert_eq!(audit[1].3.as_deref(), Some(load_operation_id.as_str()));
    assert_eq!(audit[2].3.as_deref(), Some(load_operation_id.as_str()));
    assert_eq!(audit[4].2.as_deref(), Some("inference/active"));
    assert_eq!(audit[4].3.as_deref(), Some(unload_operation_id.as_str()));
    assert_eq!(audit[5].3.as_deref(), Some(unload_operation_id.as_str()));
    let details = audit.iter().map(|row| row.4.as_str()).collect::<String>();
    assert!(!details.contains("hi"));
    assert!(!details.contains("stream me"));
    assert!(!details.contains("messages"));
}
