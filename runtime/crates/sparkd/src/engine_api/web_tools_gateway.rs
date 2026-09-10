use super::*;

use crate::web_tools::policy::{self, Surface};

/// The one key a third-party client may set to ask for the web tools on the gateway.
pub const OPT_IN_KEY: &str = "spark_web_access";

/// Did this request ask for the web tools? A body that does not ask is never given them.
pub fn wants_web_tools(body: &[u8]) -> bool {
    serde_json::from_slice::<Value>(body)
        .ok()
        .and_then(|value| {
            value
                .get("metadata")
                .and_then(|metadata| metadata.get(OPT_IN_KEY))
                .map(|opt_in| opt_in == &json!(true) || opt_in == &json!("true"))
        })
        .unwrap_or(false)
}

/// Answer a gateway request that asked for the web tools, or say why it may not have them.
pub async fn harness_completion(
    state: AppState,
    principal: Principal,
    body: Bytes,
) -> Result<Response, (StatusCode, Json<Value>)> {
    // Shared access never reaches the web tools, and that refusal is by role rather than by parameter name.
    crate::guest::refuse_guest(&state, &principal, "v1/chat/completions")?;
    state
        .require(&principal, Capability::InferenceRun)
        .resource("v1/chat/completions")
        .details(json!({"web_tools": true}))
        .check()?;
    if let Ok(parsed) = serde_json::from_slice::<Value>(&body) {
        crate::guest::reject_forbidden_parameters(&principal, &parsed)?;
    }
    let settings = crate::automations_api::web_settings::load(&state);
    // A harness needs its own policy value; the owner's chats setting never grants it.
    policy::permits(&settings, Surface::Harness)
        .map_err(|code| err(code, policy::explanation(code), StatusCode::FORBIDDEN))?;
    let request = parse_chat(&body)?;
    let value: Value = serde_json::from_slice(&body).map_err(|_| {
        err(
            "MODEL_RECIPE_INVALID",
            "invalid JSON body",
            StatusCode::UNPROCESSABLE_ENTITY,
        )
    })?;
    let conversation = value
        .get("messages")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    // Account for the run the way the proxy does: this branch consumes the same engine.
    let started = std::time::Instant::now();
    let mut attempt = crate::request_history::Attempt::begin(
        &state,
        &principal,
        &request.requested_model,
        started.elapsed().as_secs_f64() * 1000.0,
    );
    let recorder = UsageRecorder::new(&state, &principal, &request.requested_model, None);
    let prompt_bytes = body.len();
    let answer = crate::automations::runner::answer(
        &state,
        settings,
        Surface::Harness,
        crate::automations::runner::WebActor::principal(&principal),
        &request.requested_model,
        None,
        conversation,
    )
    .await
    .map_err(|code| {
        if let Some(attempt) = &mut attempt {
            attempt.finish("failed", Some(code), None);
        }
        err(
            code,
            crate::web_tools::tool_loop::stopped_text(code),
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    let elapsed = started.elapsed();
    if let Some(attempt) = &mut attempt {
        attempt.finish(
            if answer.error_code.is_none() {
                "succeeded"
            } else {
                "incomplete"
            },
            answer.error_code.as_deref(),
            None,
        );
    }
    if let Some(recorder) = &recorder {
        // The tool loop reaches the engine on loopback and never sees a usage chunk, so the charge is a stand-in.
        let estimate = UsageTotals::estimate(prompt_bytes, answer.text.len(), 1);
        recorder.record(&UsageTotals::default(), &estimate, Duration::ZERO, elapsed);
    }
    if let Some(code) = answer.error_code.as_deref() {
        return Err(err(code, &answer.text, StatusCode::SERVICE_UNAVAILABLE));
    }
    completion_response(
        answer,
        &request.requested_model,
        request.stream,
        state.clock.now().unix_timestamp(),
    )
}

fn completion_response(
    answer: crate::web_tools::tool_loop::Answer,
    model: &str,
    stream: bool,
    created: i64,
) -> Result<Response, (StatusCode, Json<Value>)> {
    let id = format!("chatcmpl-{}", uuid::Uuid::new_v4());
    let finish = if answer.truncated { "length" } else { "stop" };
    let records = answer
        .records
        .iter()
        .map(|record| record.to_json())
        .collect::<Vec<_>>();
    if stream {
        // Send the completed answer as SSE; JSON encoding prevents model text from injecting events.
        let content = json!({
            "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
            "choices": [{"index": 0, "delta": {"role": "assistant", "content": answer.text}, "finish_reason": null}],
        });
        let terminal = json!({
            "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
            "choices": [{"index": 0, "delta": {}, "finish_reason": finish}],
            "spark_web_tool_calls": records,
        });
        return Response::builder()
            .status(StatusCode::OK)
            .header(CONTENT_TYPE, "text/event-stream")
            .header("cache-control", "no-cache")
            .body(Body::from(format!(
                "data: {content}\n\ndata: {terminal}\n\ndata: [DONE]\n\n"
            )))
            .map_err(|error| crate::models::internal_envelope(&error.to_string()));
    }
    let payload = json!({
        "id": id,
        "object": "chat.completion",
        "created": created,
        "model": model,
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": answer.text},
            "finish_reason": finish,
        }],
        "spark_web_tool_calls": records,
    });
    Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, "application/json")
        .body(Body::from(payload.to_string()))
        .map_err(|error| crate::models::internal_envelope(&error.to_string()))
}

#[cfg(test)]
#[path = "web_tools_gateway/tests.rs"]
mod tests;
