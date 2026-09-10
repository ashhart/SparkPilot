use super::*;

/// Bound buffered completions so runaway engine responses cannot exhaust the daemon.
pub(super) const MAX_NON_STREAM_RESPONSE_BYTES: usize = 64 * 1024 * 1024;

/// Read a response body, refusing one that grows past `limit`.
pub(super) async fn read_bounded(
    response: reqwest::Response,
    limit: usize,
) -> Result<Vec<u8>, reqwest::Error> {
    let mut collected: Vec<u8> = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if collected.len().saturating_add(chunk.len()) > limit {
            break;
        }
        collected.extend_from_slice(&chunk);
    }
    Ok(collected)
}

/// §31.8: the only upstream paths this proxy may address; vLLM's admin surface is absent by design.
pub(super) const UPSTREAM_PATHS: [&str; 4] = [
    "/v1/chat/completions",
    "/v1/responses",
    "/v1/messages",
    "/v1/messages/count_tokens",
];

pub(super) fn upstream_path_permitted(path: &str) -> bool {
    UPSTREAM_PATHS.contains(&path)
}

pub(super) async fn proxy_openai_with_qualification(
    state: AppState,
    principal: Principal,
    body: Bytes,
    resource: &str,
    upstream_path: &str,
    allowlist: &[&str],
    qualified: bool,
) -> Result<Response, (StatusCode, Json<Value>)> {
    if !upstream_path_permitted(upstream_path) {
        return Err(crate::models::internal_envelope(
            "that upstream path is not proxyable",
        ));
    }
    state
        .require(&principal, Capability::InferenceRun)
        .resource(resource)
        .check()?;
    // Sanitize before admission so rejected bodies cannot change active-request counts or idle timing.
    let request = parse_openai(&body, allowlist)?;
    if let Ok(parsed) = serde_json::from_slice::<Value>(&body) {
        crate::guest::reject_forbidden_parameters(&principal, &parsed)?;
    }
    // Apply the owner's shared-access policy before the engine sees a guest request at all.
    let guest = crate::guest::admit(&state, &principal, &request.requested_model, resource)?;
    let admission_started = std::time::Instant::now();
    let cluster_route = cluster_inference_route(
        &state,
        None,
        Some(&request.requested_model),
        true,
        qualified,
    )?;
    if let Some(route) = &cluster_route {
        verify_cluster_route_health(route).await?;
    }
    let fixed_target = cluster_route.is_none();
    let (mut ticket, upstream) = if let Some(route) = cluster_route {
        let ticket = InferenceRequestTicket::cluster(&route);
        (ticket, route.upstream)
    } else {
        let Some(manager) = &state.engine.manager else {
            return Err(crate::models::internal_envelope("engine unavailable"));
        };
        let (ticket, upstream) = manager
            .admit_request(&request.requested_model)
            .map_err(|e| {
                crate::request_history::record_refused(
                    &state,
                    &principal,
                    &request.requested_model,
                    e.code(),
                    admission_started.elapsed().as_secs_f64() * 1000.0,
                );
                e.envelope()
            })?;
        (InferenceRequestTicket::Local(ticket), upstream)
    };
    let count_only = upstream_path == "/v1/messages/count_tokens";
    let mut attempt = (fixed_target && !count_only)
        .then(|| {
            crate::request_history::Attempt::begin(
                &state,
                &principal,
                &upstream.model_id,
                admission_started.elapsed().as_secs_f64() * 1000.0,
            )
        })
        .flatten();
    let attempt_id = attempt.as_ref().map(|entry| entry.id().to_string());
    let guest_limits =
        guest
            .as_ref()
            .map(|admission| super::openai_requests::GuestUpstreamLimits {
                remaining_tokens: admission.remaining_tokens,
                ceiling_key: super::openai_requests::ceiling_key(allowlist),
            });
    let mut upstream_body = request.upstream_body_for_guest(&upstream.served_name, guest_limits)?;
    let stream = request.stream;

    // Build a fresh upstream request without forwarding client headers.
    let url = format!("http://127.0.0.1:{}{upstream_path}", upstream.host_port);
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| crate::models::internal_envelope(&e.to_string()))?;
    let reservation = if let Some(admission) = &guest {
        let mut payload: Value = serde_json::from_slice(&upstream_body)
            .map_err(|_| crate::models::internal_envelope("request encoding failed"))?;
        let messages = crate::guest::budget::text_messages(&payload).ok_or_else(|| {
            err(
                "GUEST_INPUT_UNSUPPORTED",
                "Shared access supports text chat through /v1/chat/completions.",
                StatusCode::UNPROCESSABLE_ENTITY,
            )
        })?;
        let mut tokenize = client.post(format!("http://127.0.0.1:{}/tokenize", upstream.host_port))
            .timeout(Duration::from_secs(20))
            .json(&json!({"model": upstream.served_name, "messages": messages, "add_generation_prompt": true}));
        if !upstream.api_key.is_empty() {
            tokenize = tokenize.bearer_auth(&upstream.api_key);
        }
        let counted = tokenize.send().await.map_err(|_| {
            err(
                "GUEST_BUDGET_UNAVAILABLE",
                "Your Spark could not check the size of this request. Try again.",
                StatusCode::SERVICE_UNAVAILABLE,
            )
        })?;
        if !counted.status().is_success() {
            return Err(err(
                "GUEST_BUDGET_UNAVAILABLE",
                "This engine cannot check shared-access token budgets.",
                StatusCode::SERVICE_UNAVAILABLE,
            ));
        }
        let bytes = read_bounded(counted, 8 * 1024 * 1024).await.map_err(|_| {
            err(
                "GUEST_BUDGET_UNAVAILABLE",
                "Token counting was interrupted.",
                StatusCode::SERVICE_UNAVAILABLE,
            )
        })?;
        let counted: Value = serde_json::from_slice(&bytes).map_err(|_| {
            err(
                "GUEST_BUDGET_UNAVAILABLE",
                "The engine did not return a token count.",
                StatusCode::SERVICE_UNAVAILABLE,
            )
        })?;
        let prompt = counted
            .get("count")
            .and_then(Value::as_u64)
            .filter(|value| *value > 0)
            .ok_or_else(|| {
                err(
                    "GUEST_BUDGET_UNAVAILABLE",
                    "The engine did not return a token count.",
                    StatusCode::SERVICE_UNAVAILABLE,
                )
            })?;
        let context = counted
            .get("max_model_len")
            .and_then(Value::as_u64)
            .unwrap_or(prompt);
        let requested = payload
            .get("max_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(2048)
            .min(context.saturating_sub(prompt));
        let (reservation, limit) = crate::guest::budget::reserve(&state, admission, &upstream.model_id, prompt, requested)
            .map_err(|code| err(code, "Shared access has no allowance for this request; try a shorter chat or ask the owner to review access.", StatusCode::TOO_MANY_REQUESTS))?;
        payload["max_tokens"] = limit.into();
        if stream {
            payload["stream_options"] = json!({"include_usage": true});
        }
        upstream_body = serde_json::to_vec(&payload)
            .map_err(|_| crate::models::internal_envelope("request encoding failed"))?;
        Some(reservation)
    } else {
        None
    };
    let mut request = client.post(&url);
    if !upstream.api_key.is_empty() {
        request = request.bearer_auth(&upstream.api_key);
    }
    let prompt_bytes = upstream_body.len();
    let send = request
        .header(CONTENT_TYPE, "application/json")
        .body(upstream_body)
        .send();
    let upstream_response = tokio::select! {
        biased;
        () = wait_attempt_cancel(&mut attempt) => {
            return Err(err("REQUEST_CANCELLED", "Request cancelled; engine termination is unconfirmed.", StatusCode::CONFLICT));
        }
        loss = ticket.wait_cluster_failure() => {
            return Err(crate::cluster_inference::peer_loss_envelope(loss));
        }
        result = send => result.map_err(|e| {
            if let Some(attempt) = &mut attempt { attempt.finish("failed",Some("UPSTREAM_UNREACHABLE"),None); }
            err(
                "MODEL_LOAD_FAILED",
                format!("upstream unreachable: {e}"),
                StatusCode::INTERNAL_SERVER_ERROR,
            )
        })?,
    };
    let upstream_status = upstream_response.status();
    let content_type = upstream_response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/json")
        .to_owned();

    if !upstream_status.is_success()
        && let Some(attempt) = &mut attempt
    {
        attempt.finish("failed", Some("UPSTREAM_REFUSED"), None);
    }
    let guest_attribution = guest
        .as_ref()
        .map(|admission| (admission.device_id, admission.local_day.clone()));
    let mut recorder = if count_only {
        None
    } else {
        UsageRecorder::new(&state, &principal, &upstream.model_id, guest_attribution)
    };
    if let Some(recorder) = &mut recorder {
        recorder.reservation = reservation;
    }
    if stream {
        let mut tee = UsageTee::new(upstream_response.bytes_stream(), ticket, recorder);
        tee.attempt = attempt;
        tee.prompt_bytes = prompt_bytes;
        tee.guest_slot = guest.map(|admission| admission.slot);
        let mut builder = Response::builder();
        if let Some(id) = attempt_id {
            builder = builder.header("x-spark-inference-attempt-id", id);
        }
        return builder
            .status(upstream_status)
            .header(CONTENT_TYPE, content_type)
            .body(Body::from_stream(tee))
            .map_err(|e| crate::models::internal_envelope(&e.to_string()));
    }

    // Non-stream: bounded response; read, count usage, forward verbatim.
    let bytes = tokio::select! {
        biased;
        () = wait_attempt_cancel(&mut attempt) => {
            return Err(err("REQUEST_CANCELLED", "Request cancelled; engine termination is unconfirmed.", StatusCode::CONFLICT));
        }
        loss = ticket.wait_cluster_failure() => {
            return Err(crate::cluster_inference::peer_loss_envelope(loss));
        }
        // Bound nonstreaming engine responses even when the image and loopback endpoint are trusted.
        result = read_bounded(upstream_response, MAX_NON_STREAM_RESPONSE_BYTES) => result.map_err(|e| {
            if let Some(attempt) = &mut attempt { attempt.finish("failed",Some("UPSTREAM_READ_FAILED"),None); }
            err(
                "MODEL_LOAD_FAILED",
                format!("upstream read failed: {e}"),
                StatusCode::INTERNAL_SERVER_ERROR,
            )
        })?,
    };
    if count_only {
        // Token counting holds admission while running, but is not a generated completion or billed usage.
        ticket.note_complete(None);
        return Response::builder()
            .status(upstream_status)
            .header(CONTENT_TYPE, content_type)
            .body(Body::from(bytes))
            .map_err(|e| crate::models::internal_envelope(&e.to_string()));
    }
    let mut usage = serde_json::from_slice::<Value>(&bytes)
        .ok()
        .and_then(|v| UsageTotals::from_json(&v))
        .unwrap_or_default();
    usage.precise_counts &= upstream_status.is_success()
        && serde_json::from_slice::<Value>(&bytes)
            .ok()
            .as_ref()
            .is_some_and(valid_nonstream_completion);
    if let Some(attempt) = &mut attempt {
        // Buffered completion latency is not first-token or first-frame time.
        let parsed = serde_json::from_slice::<Value>(&bytes).ok();
        let valid = parsed.as_ref().is_some_and(valid_nonstream_completion);
        attempt.finish(
            if valid { "succeeded" } else { "incomplete" },
            if valid {
                None
            } else {
                Some("INVALID_COMPLETION")
            },
            usage
                .precise_counts
                .then_some((usage.prompt_tokens, usage.completion_tokens)),
        );
    }
    ticket.note_first_frame();
    if let Some(recorder) = &recorder {
        let elapsed = ticket.elapsed().unwrap_or_default();
        let ttft = Duration::from_secs_f64(ticket.ttft_ms().map(|ms| ms / 1000.0).unwrap_or(0.0));
        let estimate = UsageTotals::estimate(prompt_bytes, bytes.len(), 1);
        recorder.record(&usage, &estimate, ttft, elapsed.saturating_sub(ttft));
    }
    let tps = usage.tokens_per_second(&ticket);
    ticket.note_complete(tps);
    let mut builder = Response::builder();
    if let Some(id) = attempt_id {
        builder = builder.header("x-spark-inference-attempt-id", id);
    }
    builder
        .status(upstream_status)
        .header(CONTENT_TYPE, content_type)
        .body(Body::from(bytes))
        .map_err(|e| crate::models::internal_envelope(&e.to_string()))
}

pub(super) async fn wait_attempt_cancel(attempt: &mut Option<crate::request_history::Attempt>) {
    if let Some(attempt) = attempt {
        attempt.cancelled().await;
    } else {
        std::future::pending::<()>().await;
    }
}

pub(super) fn valid_nonstream_completion(value: &Value) -> bool {
    if value.get("error").is_some() {
        return false;
    }
    if value.get("type").and_then(Value::as_str) == Some("message") {
        return value
            .get("stop_reason")
            .and_then(Value::as_str)
            .is_some_and(|reason| {
                ["end_turn", "max_tokens", "stop_sequence", "tool_use"].contains(&reason)
            })
            && value
                .get("content")
                .and_then(Value::as_array)
                .is_some_and(|blocks| {
                    blocks.iter().any(|block| {
                        block.get("type").and_then(Value::as_str) == Some("tool_use")
                            || ["text", "thinking"].iter().any(|key| {
                                block
                                    .get(*key)
                                    .and_then(Value::as_str)
                                    .is_some_and(|v| !v.is_empty())
                            })
                    })
                });
    }
    value
        .get("choices")
        .and_then(Value::as_array)
        .is_some_and(|choices| {
            choices.iter().any(|choice| {
                choice
                    .get("finish_reason")
                    .and_then(Value::as_str)
                    .is_some_and(|v| ["stop", "length", "tool_calls"].contains(&v))
                    && choice.get("message").is_some_and(|message| {
                        ["content", "reasoning_content", "reasoning"]
                            .iter()
                            .any(|key| {
                                message
                                    .get(key)
                                    .and_then(Value::as_str)
                                    .is_some_and(|v| !v.is_empty())
                            })
                            || message
                                .get("tool_calls")
                                .and_then(Value::as_array)
                                .is_some_and(|v| !v.is_empty())
                    })
            })
        })
        || (value.get("status").and_then(Value::as_str) == Some("completed")
            && value
                .get("output")
                .and_then(Value::as_array)
                .is_some_and(|v| !v.is_empty()))
}

#[cfg(test)]
mod upstream_path_tests {
    use super::upstream_path_permitted;

    #[test]
    fn the_engines_administrative_surface_is_never_proxyable() {
        for path in [
            "/sleep",
            "/wake_up",
            "/collective_rpc",
            "/reset_prefix_cache",
            "/start_profile",
            "/stop_profile",
            "/v1/chat/completions/../sleep",
            "/v1/chat/completions?x=1",
            "",
        ] {
            assert!(!upstream_path_permitted(path), "{path} must not be proxied");
        }
        assert!(upstream_path_permitted("/v1/chat/completions"));
        assert!(upstream_path_permitted("/v1/responses"));
    }
}
