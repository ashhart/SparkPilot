use super::*;

pub(super) async fn health_stub() -> Json<Value> {
    Json(json!({ "status": "ok" }))
}

pub(super) fn mock_router(shared: Arc<MockShared>) -> axum::Router {
    axum::Router::new()
        .route("/health", get(health_stub))
        .route("/v1/models", get(get_models))
        .route("/v1/chat/completions", post(chat_completions_stub))
        .route("/v1/responses", post(responses_stub))
        .route("/v1/messages", post(messages_stub))
        .route("/v1/messages/count_tokens", post(count_tokens_stub))
        .route("/tokenize", post(tokenize_stub))
        .layer(DefaultBodyLimit::max(16 * 1024 * 1024))
        .with_state(shared)
}

async fn count_tokens_stub(Json(_value): Json<Value>) -> Json<Value> {
    Json(json!({"input_tokens": 12}))
}

async fn messages_stub(
    State(shared): State<Arc<MockShared>>,
    Json(value): Json<Value>,
) -> Response {
    let served = shared
        .served_name
        .lock()
        .expect("served lock")
        .clone()
        .unwrap_or_else(|| "mock".into());
    shared.completions.fetch_add(1, Ordering::Relaxed);
    if value.get("stream").and_then(Value::as_bool) != Some(true) {
        return Json(json!({"id":"msg_mock", "type":"message", "role":"assistant", "model":served,
            "content":[{"type":"text", "text":"Hello from the mock engine."}], "stop_reason":"end_turn",
            "usage":{"input_tokens":12,"output_tokens":14}})).into_response();
    }
    let events = [
        json!({"type":"message_start","message":{"id":"msg_mock","type":"message","role":"assistant","model":served,"content":[],"usage":{"input_tokens":12,"output_tokens":0}}}),
        json!({"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
        json!({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello from the mock engine."}}),
        json!({"type":"content_block_stop","index":0}),
        json!({"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":14}}),
        json!({"type":"message_stop"}),
    ];
    let stream = futures::stream::iter(events.into_iter().map(|value| {
        Ok::<_, Infallible>(
            Event::default()
                .event(value["type"].as_str().unwrap())
                .data(value.to_string()),
        )
    }));
    Sse::new(stream).into_response()
}

async fn tokenize_stub(Json(value): Json<Value>) -> Response {
    if value
        .get("messages")
        .and_then(Value::as_array)
        .is_none_or(Vec::is_empty)
    {
        return axum::http::StatusCode::BAD_REQUEST.into_response();
    }
    Json(json!({"count": 12, "max_model_len": 16384})).into_response()
}

pub(super) async fn get_models(State(shared): State<Arc<MockShared>>) -> Json<Value> {
    let served = shared
        .served_name
        .lock()
        .expect("served lock")
        .clone()
        .unwrap_or_else(|| "mock".to_owned());
    Json(json!({
        "object": "list",
        "data": [{ "id": served, "object": "model" }]
    }))
}

pub(super) async fn chat_completions_stub(
    State(shared): State<Arc<MockShared>>,
    body: axum::body::Bytes,
) -> Response {
    let value: Value = serde_json::from_slice(&body).unwrap_or_default();
    if shared.text_tool_mode.load(Ordering::Relaxed)
        && value
            .get("tools")
            .and_then(Value::as_array)
            .is_some_and(|tools| !tools.is_empty())
        && value.get("tool_choice") != Some(&json!("none"))
    {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({"error": "automatic tool choice is not enabled"})),
        )
            .into_response();
    }
    let stream = value
        .get("stream")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let served = shared
        .served_name
        .lock()
        .expect("served lock")
        .clone()
        .unwrap_or_else(|| "mock".to_owned());
    shared.completions.fetch_add(1, Ordering::Relaxed);

    let usage = json!({
        "prompt_tokens": 12,
        "completion_tokens": 14,
        "total_tokens": 26
    });

    if !stream {
        let delay = shared.non_stream_delay_millis.load(Ordering::Relaxed);
        if delay > 0 {
            tokio::time::sleep(Duration::from_millis(delay)).await;
        }
        return Json(json!({
            "id": "chatcmpl-mock",
            "object": "chat.completion",
            "created": 0,
            "model": served,
            "choices": [{
                "index": 0,
                "message": { "role": "assistant", "content": "Hello from the mock engine." },
                "finish_reason": "stop"
            }],
            "usage": usage
        }))
        .into_response();
    }

    // Send content, completion and usage frames; optionally stall after the first chunk to test disconnect cancellation.
    let chunks = [
        json!({"id":"chatcmpl-mock","object":"chat.completion.chunk","created":0,
               "model":served,
               "choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}),
        json!({"id":"chatcmpl-mock","object":"chat.completion.chunk","created":0,
               "model":served,
               "choices":[{"index":0,"delta":{"content":" from"},"finish_reason":null}]}),
        json!({"id":"chatcmpl-mock","object":"chat.completion.chunk","created":0,
               "model":served,
               "choices":[{"index":0,"delta":{"content":" Spark."},"finish_reason":null}]}),
        json!({"id":"chatcmpl-mock","object":"chat.completion.chunk","created":0,
               "model":served,
               "choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}),
        json!({"id":"chatcmpl-mock","object":"chat.completion.chunk","created":0,
               "model":served, "usage": usage}),
    ];
    let stall = shared.stall_after_first.load(Ordering::Relaxed);
    let (tx, rx) = mpsc::channel::<Result<Event, Infallible>>(8);
    let shared_for_guard = shared.clone();
    tokio::spawn(async move {
        for (index, chunk) in chunks.iter().enumerate() {
            if shared.omit_usage.load(Ordering::Relaxed) && chunk.get("usage").is_some() {
                continue;
            }
            let event = Event::default()
                .id((index + 1).to_string())
                .event("message")
                .data(chunk.to_string());
            if tx.send(Ok(event)).await.is_err() {
                return;
            }
            if index == 0 && stall {
                tokio::time::sleep(Duration::from_secs(30)).await;
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let done = Event::default()
            .id((chunks.len() + 1).to_string())
            .event("message")
            .data("[DONE]");
        let _ = tx.send(Ok(done)).await;
    });

    let stream = AbortGuardStream {
        inner: ReceiverStream::new(rx),
        shared: shared_for_guard,
    };
    Sse::new(stream).into_response()
}

pub(super) async fn responses_stub(
    State(shared): State<Arc<MockShared>>,
    body: axum::body::Bytes,
) -> Response {
    let value: Value = serde_json::from_slice(&body).unwrap_or_default();
    let stream = value
        .get("stream")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let served = shared
        .served_name
        .lock()
        .expect("served lock")
        .clone()
        .unwrap_or_else(|| "mock".to_owned());
    shared.completions.fetch_add(1, Ordering::Relaxed);

    let completed = json!({
        "id": "resp-mock",
        "object": "response",
        "status": "completed",
        "model": served,
        "output": [{
            "id": "msg-mock",
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [{
                "type": "output_text",
                "text": "Hello from Spark.",
                "annotations": []
            }]
        }],
        "usage": {"input_tokens": 12, "output_tokens": 14, "total_tokens": 26}
    });
    if !stream {
        return Json(completed).into_response();
    }

    let events = [
        json!({"type":"response.created","response":{"id":"resp-mock","object":"response","status":"in_progress","model":served,"output":[]}}),
        json!({"type":"response.output_text.delta","item_id":"msg-mock","output_index":0,"content_index":0,"delta":"Hello from Spark."}),
        json!({"type":"response.completed","response":completed}),
    ];
    let stream = futures::stream::iter(events.into_iter().map(|event| {
        Ok::<_, std::convert::Infallible>(format!(
            "event: {}\ndata: {event}\n\n",
            event["type"].as_str().unwrap_or("message")
        ))
    }));
    Response::builder()
        .header(axum::http::header::CONTENT_TYPE, "text/event-stream")
        .body(Body::from_stream(stream))
        .expect("mock responses stream")
}

/// Detect client disconnect through SSE-wrapper drop for cancellation tests.
pub(super) struct AbortGuardStream<S> {
    pub(super) inner: S,
    pub(super) shared: Arc<MockShared>,
}

impl<S, T> Stream for AbortGuardStream<S>
where
    S: Stream<Item = T> + Unpin,
{
    type Item = T;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<T>> {
        self.inner.poll_next_unpin(cx)
    }
}

impl<S> Drop for AbortGuardStream<S> {
    fn drop(&mut self) {
        self.shared.aborted_streams.fetch_add(1, Ordering::Relaxed);
    }
}

impl<S: std::fmt::Debug> fmt::Debug for AbortGuardStream<S> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AbortGuardStream").finish_non_exhaustive()
    }
}
