use super::*;

/// Forward only allowlisted parameters when building upstream requests.
pub(super) const ALLOWED_CHAT_PARAMS: &[&str] = &[
    "model",
    "messages",
    "stream",
    "temperature",
    "top_p",
    "max_tokens",
    "tools",
    "tool_choice",
    "thinking_token_budget",
    "response_format",
    "user",
    "metadata",
    "stream_options",
];

/// Responses API fields used by Codex-compatible developer tools.
pub(super) const ALLOWED_RESPONSES_PARAMS: &[&str] = &[
    "model",
    "input",
    "instructions",
    "tools",
    "tool_choice",
    "parallel_tool_calls",
    "reasoning",
    "text",
    "include",
    "metadata",
    "max_output_tokens",
    "previous_response_id",
    "prompt_cache_key",
    "safety_identifier",
    "store",
    "stream",
    "truncation",
];

/// Native Messages fields, available only through an authorized workspace gateway.
const ALLOWED_MESSAGES_PARAMS: &[&str] = &[
    "model",
    "messages",
    "max_tokens",
    "system",
    "stream",
    "temperature",
    "top_p",
    "top_k",
    "stop_sequences",
    "tools",
    "tool_choice",
    "output_config",
];
const ALLOWED_COUNT_PARAMS: &[&str] = &["model", "messages", "system", "tools", "tool_choice"];

/// Parameters that are never accepted, even as ignored input.
pub(super) const BANNED_CHAT_PARAMS: &[&str] = &[
    "guided_json",
    "guided_regex",
    "guided_choice",
    "chat_template_kwargs",
    "detokenize",
    "skip_special_tokens",
];

/// What a guest's policy forces into the upstream body whatever the client asked for.
#[derive(Debug, Clone, Copy)]
pub(super) struct GuestUpstreamLimits {
    /// What is left of the guest's day; the engine is never asked to generate more than this.
    pub(super) remaining_tokens: u64,
    /// The output-ceiling field this endpoint accepts.
    pub(super) ceiling_key: &'static str,
}

/// The output-ceiling field each OpenAI-compatible endpoint names.
pub(super) fn ceiling_key(allowlist: &[&str]) -> &'static str {
    if allowlist.contains(&"max_output_tokens") {
        "max_output_tokens"
    } else {
        "max_tokens"
    }
}

/// Carry sanitized client input before admission; the engine decides readiness and model identity under its own lock.
pub struct ChatRequest {
    pub requested_model: String,
    pub stream: bool,
    pub(super) forwarded: Map<String, Value>,
}

impl ChatRequest {
    /// Use the admitted engine's served name so concurrent loads cannot leave stale caller-selected routing in the body.
    pub fn upstream_body(&self, served_name: &str) -> Result<Vec<u8>, (StatusCode, Json<Value>)> {
        self.upstream_body_for_guest(served_name, None)
    }

    /// Build the upstream body, holding a guest to reported usage and to what is left of its day.
    pub(super) fn upstream_body_for_guest(
        &self,
        served_name: &str,
        guest: Option<GuestUpstreamLimits>,
    ) -> Result<Vec<u8>, (StatusCode, Json<Value>)> {
        let mut forwarded = self.forwarded.clone();
        forwarded.insert("model".to_owned(), Value::String(served_name.to_owned()));
        if let Some(limits) = guest {
            apply_guest_limits(&mut forwarded, self.stream, limits);
        }
        serde_json::to_vec(&Value::Object(forwarded))
            .map_err(|error| crate::models::internal_envelope(&error.to_string()))
    }
}

/// vLLM reports usage only when the client asks, and a guest's budget cannot depend on the client asking.
pub(super) fn apply_guest_limits(
    forwarded: &mut Map<String, Value>,
    stream: bool,
    limits: GuestUpstreamLimits,
) {
    if stream {
        let options = forwarded
            .entry("stream_options".to_owned())
            .or_insert_with(|| Value::Object(Map::new()));
        if !options.is_object() {
            *options = Value::Object(Map::new());
        }
        if let Some(object) = options.as_object_mut() {
            object.insert("include_usage".to_owned(), Value::Bool(true));
        }
    }
    // Absent, oversized or unreadable: the ceiling is what the guest has left, never more.
    let ceiling = limits.remaining_tokens.min(i64::MAX as u64) as i64;
    let asked = forwarded.get(limits.ceiling_key).and_then(Value::as_i64);
    let bounded = asked
        .filter(|value| *value > 0)
        .unwrap_or(ceiling)
        .min(ceiling);
    forwarded.insert(limits.ceiling_key.to_owned(), Value::from(bounded));
}

/// Reject malformed, banned or oversized input before consulting or accounting against the engine.
pub fn parse_chat(client_body: &[u8]) -> Result<ChatRequest, (StatusCode, Json<Value>)> {
    parse_openai(client_body, ALLOWED_CHAT_PARAMS)
}

pub(super) fn parse_openai(
    client_body: &[u8],
    allowlist: &[&str],
) -> Result<ChatRequest, (StatusCode, Json<Value>)> {
    let value: Value = serde_json::from_slice(client_body).map_err(|_| {
        err(
            "MODEL_RECIPE_INVALID",
            "invalid JSON body",
            StatusCode::UNPROCESSABLE_ENTITY,
        )
    })?;
    for banned in BANNED_CHAT_PARAMS {
        if value.get(*banned).is_some() {
            return Err(err(
                "MODEL_RECIPE_INVALID",
                format!("parameter {banned} is not allowed"),
                StatusCode::BAD_REQUEST,
            ));
        }
    }
    if let Some(budget) = value.get("thinking_token_budget")
        && budget.as_u64().is_none_or(|budget| budget > 8192)
    {
        return Err(err(
            "MODEL_RECIPE_INVALID",
            "Thinking budget must be an integer from 0 to 8192.",
            StatusCode::BAD_REQUEST,
        ));
    }
    let mut forwarded = Map::new();
    for key in allowlist {
        if let Some(v) = value.get(*key) {
            forwarded.insert((*key).to_owned(), v.clone());
        }
    }
    Ok(ChatRequest {
        requested_model: value
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        stream: value
            .get("stream")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        forwarded,
    })
}

pub async fn chat_completions(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    body: Bytes,
) -> Result<Response, (StatusCode, Json<Value>)> {
    chat_completions_with_qualification(
        state,
        principal,
        body,
        crate::cluster_coordination::CLUSTER_INFERENCE_QUALIFIED,
    )
    .await
}

pub(crate) async fn chat_completions_with_qualification(
    state: AppState,
    principal: Principal,
    body: Bytes,
    qualified: bool,
) -> Result<Response, (StatusCode, Json<Value>)> {
    // A third-party client only reaches the web tools by asking, and only when the owner allowed harnesses.
    if super::wants_web_tools(&body) {
        return super::harness_completion(state, principal, body).await;
    }
    proxy_openai_with_qualification(
        state,
        principal,
        body,
        "v1/chat/completions",
        "/v1/chat/completions",
        ALLOWED_CHAT_PARAMS,
        qualified,
    )
    .await
}

/// Codex-compatible, allowlisted proxy to the active vLLM engine.
pub async fn openai_responses(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    body: Bytes,
) -> Result<Response, (StatusCode, Json<Value>)> {
    proxy_openai_with_qualification(
        state,
        principal,
        body,
        "v1/responses",
        "/v1/responses",
        ALLOWED_RESPONSES_PARAMS,
        crate::cluster_coordination::CLUSTER_INFERENCE_QUALIFIED,
    )
    .await
}

/// Preserve the native protocol while using the same model admission, local credentials and request limits.
pub(crate) async fn anthropic_messages(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    body: Bytes,
    count_only: bool,
) -> Result<Response, (StatusCode, Json<Value>)> {
    let (path, allowed) = if count_only {
        ("/v1/messages/count_tokens", ALLOWED_COUNT_PARAMS)
    } else {
        ("/v1/messages", ALLOWED_MESSAGES_PARAMS)
    };
    proxy_openai_with_qualification(
        state,
        principal,
        body,
        "projects/terminal",
        path,
        allowed,
        crate::cluster_coordination::CLUSTER_INFERENCE_QUALIFIED,
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn guest(remaining: u64, key: &'static str) -> GuestUpstreamLimits {
        GuestUpstreamLimits {
            remaining_tokens: remaining,
            ceiling_key: key,
        }
    }

    fn body(request: &ChatRequest, limits: Option<GuestUpstreamLimits>) -> Value {
        serde_json::from_slice(
            &request
                .upstream_body_for_guest("served", limits)
                .expect("body"),
        )
        .expect("json")
    }

    /// BH-07: vLLM reports usage only when the client asks, so a guest's budget cannot depend on the client asking.
    #[test]
    fn a_guest_body_asks_for_usage_and_cannot_outrun_what_is_left_of_its_day() {
        let asked = parse_chat(br#"{"model":"m","stream":true,"max_tokens":100000,"messages":[]}"#)
            .expect("parse");
        let sent = body(&asked, Some(guest(900, "max_tokens")));
        assert_eq!(sent["stream_options"]["include_usage"], json!(true));
        assert_eq!(sent["max_tokens"], json!(900));

        let silent = parse_chat(br#"{"model":"m","stream":true,"messages":[]}"#).expect("parse");
        let sent = body(&silent, Some(guest(900, "max_tokens")));
        assert_eq!(
            sent["stream_options"]["include_usage"],
            json!(true),
            "a body with no stream_options must still report usage"
        );
        assert_eq!(
            sent["max_tokens"],
            json!(900),
            "a body with no ceiling must still be given one"
        );
    }

    /// BH-07: the ceiling follows the endpoint, a smaller one the caller chose is kept, and a non-guest body is sent as written.
    #[test]
    fn the_ceiling_follows_the_endpoint_and_only_a_guest_is_given_one() {
        assert_eq!(ceiling_key(ALLOWED_CHAT_PARAMS), "max_tokens");
        assert_eq!(ceiling_key(ALLOWED_RESPONSES_PARAMS), "max_output_tokens");

        let responses = parse_openai(
            br#"{"model":"m","stream":true,"max_output_tokens":50,"input":[]}"#,
            ALLOWED_RESPONSES_PARAMS,
        )
        .expect("parse");
        let sent = body(&responses, Some(guest(900, "max_output_tokens")));
        assert_eq!(sent["max_output_tokens"], json!(50));

        let owner = parse_chat(br#"{"model":"m","stream":true,"messages":[]}"#).expect("parse");
        let sent = body(&owner, None);
        assert!(sent.get("stream_options").is_none());
        assert!(sent.get("max_tokens").is_none());
    }

    /// A client that sent a hostile stream_options value is corrected rather than trusted.
    #[test]
    fn an_unusable_stream_options_value_is_replaced() {
        let hostile =
            parse_chat(br#"{"model":"m","stream":true,"stream_options":7,"messages":[]}"#)
                .expect("parse");
        let sent = body(&hostile, Some(guest(10, "max_tokens")));
        assert_eq!(sent["stream_options"]["include_usage"], json!(true));
        assert_eq!(sent["max_tokens"], json!(10));
    }
}

#[cfg(test)]
mod thinking_budget_tests {
    use super::*;
    #[test]
    fn thinking_budget_is_bounded_and_reaches_the_engine() {
        for budget in [json!(0), json!(256), json!(8192)] {
            let request = parse_chat(
                &serde_json::to_vec(
                    &json!({"model":"m","messages":[],"thinking_token_budget":budget}),
                )
                .unwrap(),
            )
            .unwrap();
            let body: Value = serde_json::from_slice(&request.upstream_body("m").unwrap()).unwrap();
            assert_eq!(body["thinking_token_budget"], budget);
        }
        for budget in [
            json!(-1),
            json!(8193),
            json!(true),
            json!(1.5),
            json!("256"),
        ] {
            assert!(
                parse_chat(
                    &serde_json::to_vec(
                        &json!({"model":"m","messages":[],"thinking_token_budget":budget})
                    )
                    .unwrap()
                )
                .is_err()
            );
        }
    }
}
