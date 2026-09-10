use super::*;

use crate::web_tools::policy::Surface;

const WEB_ANSWER_ROUTE: &str = "/api/v1/web/answer";

#[derive(Debug, Clone, Deserialize)]
pub struct WebAnswerRequest {
    pub model: String,
    pub messages: Vec<WebAnswerMessage>,
    #[serde(default)]
    pub system_instruction: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WebAnswerMessage {
    pub role: String,
    pub content: String,
}

/// One conversation turn that may read the web, run entirely on the Spark.
pub async fn create_web_answer(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Json(request): Json<WebAnswerRequest>,
) -> Result<Json<Value>, Denial> {
    state
        .require(&principal, Capability::InferenceRun)
        .resource(WEB_ANSWER_ROUTE)
        .check()?;
    let settings = web_settings::load(&state);
    // The route decides the surface; a caller cannot claim to be an automation.
    crate::web_tools::policy::permits(&settings, Surface::Chat).map_err(|code| {
        envelope(
            StatusCode::FORBIDDEN,
            code,
            crate::web_tools::policy::explanation(code),
        )
    })?;
    let conversation = request
        .messages
        .iter()
        .filter(|message| matches!(message.role.as_str(), "system" | "user" | "assistant"))
        .map(|message| json!({"role": message.role, "content": message.content}))
        .collect::<Vec<_>>();
    let answer = crate::automations::runner::answer(
        &state,
        settings,
        Surface::Chat,
        crate::automations::runner::WebActor::principal(&principal),
        &request.model,
        request.system_instruction.as_deref(),
        conversation,
    )
    .await
    .map_err(|code| {
        envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            code,
            crate::web_tools::tool_loop::stopped_text(code),
        )
    })?;
    if let Some(code) = answer.error_code.as_deref() {
        return Err(envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            code,
            &answer.text,
        ));
    }
    Ok(Json(json!({
        "text": answer.text,
        "model_id": request.model,
        "sources": answer
            .sources
            .iter()
            .map(|source| json!({"url": source.url, "title": source.title}))
            .collect::<Vec<_>>(),
        "tool_calls": answer
            .records
            .iter()
            .map(|record| record.to_json())
            .collect::<Vec<_>>(),
        "truncated": answer.truncated,
    })))
}
