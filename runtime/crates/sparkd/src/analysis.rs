//! Run document analysis as durable leased work against the authorized loopback engine; intent-process lifetime must not determine completion.

use std::sync::Arc;
use std::time::Duration;

use reqwest::header::CONTENT_TYPE;
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::engine::{EngineError, EngineManager};
use crate::jobs::OperationLease;

/// Bound document text to the app's 200 KB transform limit.
pub const MAX_TEXT_BYTES: usize = 200_000;
/// The caller's instruction ("summarise this", "list the action items").
pub const MAX_INSTRUCTION_BYTES: usize = 2_000;
/// Treat this as a display label, never a filesystem path.
pub const MAX_SOURCE_NAME_BYTES: usize = 200;
/// Bound generation independently of the shorter foreground-intent limit.
pub const MAX_OUTPUT_TOKENS: u64 = 2_048;
/// Used when the caller does not choose.
pub const DEFAULT_OUTPUT_TOKENS: u64 = 512;

/// Operation kind recorded on the durable row.
pub const OPERATION_KIND: &str = "inference.analysis";
/// Every bound violation answers with one code so the app has one branch.
pub const INVALID_INPUT_CODE: &str = "ANALYSIS_INPUT_INVALID";

/// Poll cancellation while generating; dropping the upstream future terminates the engine connection.
const CANCEL_POLL: Duration = Duration::from_millis(250);

/// Reject unknown fields instead of silently ignoring requested sampling parameters.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalysisBody {
    pub instruction: String,
    pub text: String,
    #[serde(default)]
    pub source_name: Option<String>,
    #[serde(default)]
    pub max_output_tokens: Option<u64>,
    #[serde(default)]
    pub target: Option<AnalysisTargetBody>,
}

/// Identity of the target selected by the caller.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalysisTargetBody {
    #[serde(default)]
    pub node_id: Option<String>,
    #[serde(default)]
    pub cluster_id: Option<String>,
}

/// Queue only validated requests constructed by AnalysisRequest::validate.
#[derive(Debug, Clone)]
pub struct AnalysisRequest {
    instruction: String,
    text: String,
    source_name: Option<String>,
    max_output_tokens: u64,
}

impl AnalysisRequest {
    /// Validate decoded bounds and return the message wrapped by ANALYSIS_INPUT_INVALID.
    pub fn validate(body: &AnalysisBody) -> Result<Self, String> {
        let instruction = body.instruction.trim();
        if instruction.is_empty() {
            return Err("instruction must not be empty".into());
        }
        if instruction.len() > MAX_INSTRUCTION_BYTES {
            return Err(format!(
                "instruction must be at most {MAX_INSTRUCTION_BYTES} bytes"
            ));
        }
        if body.text.trim().is_empty() {
            return Err("text must not be empty".into());
        }
        if body.text.len() > MAX_TEXT_BYTES {
            return Err(format!("text must be at most {MAX_TEXT_BYTES} bytes"));
        }
        let source_name = match body.source_name.as_deref().map(str::trim) {
            None | Some("") => None,
            Some(name) if name.len() > MAX_SOURCE_NAME_BYTES => {
                return Err(format!(
                    "source_name must be at most {MAX_SOURCE_NAME_BYTES} bytes"
                ));
            }
            Some(name) => Some(name.to_owned()),
        };
        let max_output_tokens = body.max_output_tokens.unwrap_or(DEFAULT_OUTPUT_TOKENS);
        if max_output_tokens == 0 || max_output_tokens > MAX_OUTPUT_TOKENS {
            return Err(format!("max_output_tokens must be 1..={MAX_OUTPUT_TOKENS}"));
        }
        Ok(Self {
            instruction: instruction.to_owned(),
            text: body.text.clone(),
            source_name,
            max_output_tokens,
        })
    }

    /// Persist document metadata without file contents; the idempotency digest already binds the exact body.
    pub fn redacted_input(&self) -> Value {
        json!({
            "instruction": self.instruction,
            "source_name": self.source_name,
            "text_bytes": self.text.len(),
            "max_output_tokens": self.max_output_tokens,
        })
    }

    /// The allowlisted chat request sent to the loopback engine.
    fn upstream_body(&self, served_name: &str) -> Value {
        // Send document content as a user message, separate from the owner's instruction.
        let mut user = String::new();
        if let Some(name) = &self.source_name {
            user.push_str("Document: ");
            user.push_str(name);
            user.push_str("\n\n");
        }
        user.push_str(&self.text);
        json!({
            "model": served_name,
            "messages": [
                { "role": "system", "content": self.instruction },
                { "role": "user", "content": user },
            ],
            "stream": false,
            "max_tokens": self.max_output_tokens,
        })
    }
}

/// Everything the worker needs that is not the request itself.
pub struct AnalysisRuntime {
    pub engine: Option<Arc<EngineManager>>,
    pub jobs: crate::jobs::JobService,
    pub database: Arc<parking_lot::Mutex<rusqlite::Connection>>,
}

/// Distinguish missing models from worker saturation so busy nodes return retryable capacity errors.
pub(crate) enum AnalysisStartError {
    Engine(EngineError),
    Spawn(crate::jobs::LeaseError),
}

impl AnalysisStartError {
    pub(crate) fn envelope(&self) -> (axum::http::StatusCode, axum::Json<Value>) {
        match self {
            AnalysisStartError::Engine(error) => error.envelope(),
            AnalysisStartError::Spawn(error) => crate::api_error::spawn_envelope(error),
        }
    }

    /// The code recorded on the failed operation row.
    pub(crate) fn code(&self) -> String {
        match self {
            AnalysisStartError::Engine(error) => error.code().to_owned(),
            AnalysisStartError::Spawn(crate::jobs::LeaseError::Overloaded(_)) => {
                "OPERATION_CAPACITY_EXCEEDED".to_owned()
            }
            AnalysisStartError::Spawn(_) => "INTERNAL".to_owned(),
        }
    }
}

/// Check the loaded engine before creating an operation that would otherwise be guaranteed to fail.
pub(crate) fn spawn(
    runtime: &AnalysisRuntime,
    operation_id: Uuid,
    request: AnalysisRequest,
    cluster_route: Option<crate::cluster_inference::ClusterInferenceRoute>,
    recorder: Option<crate::engine_api::UsageRecorder>,
) -> Result<(), AnalysisStartError> {
    let (ticket, upstream, model_id) = if let Some(route) = cluster_route {
        let ticket = crate::cluster_inference::InferenceRequestTicket::cluster(&route);
        let upstream = route.upstream;
        let model_id = upstream.model_id.clone();
        (ticket, upstream, model_id)
    } else {
        let engine = runtime
            .engine
            .as_ref()
            .ok_or(AnalysisStartError::Engine(EngineError::NotLoaded))?;
        let (ticket, upstream) = engine.begin_request().map_err(AnalysisStartError::Engine)?;
        let model_id = engine
            .view()
            .map(|view| view.model_id)
            .ok_or(AnalysisStartError::Engine(EngineError::NotLoaded))?;
        (
            crate::cluster_inference::InferenceRequestTicket::Local(ticket),
            upstream,
            model_id,
        )
    };
    runtime
        .jobs
        .spawn_leased(runtime.database.clone(), operation_id, move |lease| {
            let worker = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("analysis worker runtime");
            worker.block_on(run(lease, ticket, upstream, model_id, request, recorder));
        })
        .map_err(AnalysisStartError::Spawn)
}

/// Return from this select arm when cancellation requires stopping the worker.
async fn cancelled(lease: &OperationLease) {
    loop {
        if lease.is_cancelled() {
            return;
        }
        tokio::time::sleep(CANCEL_POLL).await;
    }
}

async fn cluster_aware<T>(
    ticket: &mut crate::cluster_inference::InferenceRequestTicket,
    future: impl std::future::Future<Output = T>,
) -> Result<T, crate::cluster_coordination::ClusterPeerLoss> {
    tokio::select! {
        biased;
        loss = ticket.wait_cluster_failure() => Err(loss),
        result = future => Ok(result),
    }
}

async fn run(
    lease: OperationLease,
    mut ticket: crate::cluster_inference::InferenceRequestTicket,
    upstream: crate::engine::EngineUpstream,
    model_id: String,
    request: AnalysisRequest,
    recorder: Option<crate::engine_api::UsageRecorder>,
) {
    let _ = lease.set_stage("analysing", Some(0.0));

    let url = format!(
        "http://127.0.0.1:{}/v1/chat/completions",
        upstream.host_port
    );
    // Build a fresh engine request without forwarding caller headers.
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("fixed loopback analysis client builds");
    let mut upstream_request = client.post(&url);
    if !upstream.api_key.is_empty() {
        upstream_request = upstream_request.bearer_auth(&upstream.api_key);
    }
    let send = upstream_request
        .header(CONTENT_TYPE, "application/json")
        .body(
            serde_json::to_vec(&request.upstream_body(&upstream.served_name))
                .expect("analysis body serialises"),
        )
        .send();

    // Cancel by dropping the upstream connection; never persist a partial answer.
    let response = tokio::select! {
        result = cluster_aware(&mut ticket, send) => {
            match result {
                Ok(response) => response,
                Err(loss) => {
                    ticket.note_complete(None);
                    lease.settle_failed(loss.request_failure_code());
                    return;
                }
            }
        },
        () = cancelled(&lease) => {
            ticket.note_complete(None);
            lease.settle_failed("OPERATION_CANCELLED");
            return;
        }
    };
    let response = match response {
        Ok(response) => response,
        Err(error) => {
            tracing::warn!(%error, "analysis upstream unreachable");
            ticket.note_complete(None);
            lease.settle_failed("MODEL_LOAD_FAILED");
            return;
        }
    };
    let status = response.status();
    ticket.note_first_frame();

    let bytes = tokio::select! {
        result = cluster_aware(&mut ticket, response.bytes()) => {
            match result {
                Ok(bytes) => bytes,
                Err(loss) => {
                    ticket.note_complete(None);
                    lease.settle_failed(loss.request_failure_code());
                    return;
                }
            }
        },
        () = cancelled(&lease) => {
            ticket.note_complete(None);
            lease.settle_failed("OPERATION_CANCELLED");
            return;
        }
    };
    let Ok(bytes) = bytes else {
        ticket.note_complete(None);
        lease.settle_failed("MODEL_LOAD_FAILED");
        return;
    };
    if !status.is_success() {
        tracing::warn!(%status, "analysis upstream refused the request");
        ticket.note_complete(None);
        lease.settle_failed("MODEL_LOAD_FAILED");
        return;
    }

    let payload: Value = match serde_json::from_slice(&bytes) {
        Ok(payload) => payload,
        Err(error) => {
            tracing::warn!(%error, "analysis upstream returned invalid JSON");
            ticket.note_complete(None);
            lease.settle_failed("MODEL_LOAD_FAILED");
            return;
        }
    };
    let Some(text) = completion_text(&payload) else {
        ticket.note_complete(None);
        lease.settle_failed("MODEL_RESPONSE_EMPTY");
        return;
    };
    let finish_reason = payload["choices"][0]["finish_reason"]
        .as_str()
        .unwrap_or_default()
        .to_owned();

    // Record durable-analysis token usage through the same accounting as proxied requests.
    let usage = crate::engine_api::UsageTotals::from_json(&payload);
    let elapsed = ticket.elapsed().unwrap_or(Duration::ZERO);
    let tokens_per_second = usage
        .as_ref()
        .and_then(|totals| totals.tokens_per_second(&ticket));
    if let (Some(recorder), Some(totals)) = (recorder.as_ref(), usage.as_ref()) {
        let ttft = Duration::from_secs_f64(ticket.ttft_ms().unwrap_or(0.0) / 1000.0);
        recorder.record_reported(totals, ttft, elapsed);
    }
    let output_tokens = usage.as_ref().map(|totals| totals.completion_tokens);
    ticket.note_complete(tokens_per_second);

    lease.settle_succeeded(&json!({
        "text": text,
        "model_id": model_id,
        "output_tokens": output_tokens,
        // Report length termination so truncated answers remain distinguishable from complete short answers.
        "truncated": finish_reason == "length",
    }));
}

/// The assistant text of a non-streaming completion.
fn completion_text(payload: &Value) -> Option<String> {
    let text = payload
        .get("choices")?
        .as_array()?
        .first()?
        .get("message")?
        .get("content")?
        .as_str()?;
    (!text.is_empty()).then(|| text.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn pending_cluster_analysis_reports_the_exact_peer_loss() {
        for loss in [
            crate::cluster_coordination::ClusterPeerLoss::Worker,
            crate::cluster_coordination::ClusterPeerLoss::Coordinator,
        ] {
            let (sender, _) = tokio::sync::watch::channel(None);
            sender.send_replace(Some(loss));
            let mut ticket =
                crate::cluster_inference::InferenceRequestTicket::cluster_with_sender(&sender);
            let result = cluster_aware(&mut ticket, std::future::pending::<()>()).await;
            assert_eq!(result.unwrap_err(), loss);
            assert!(matches!(
                loss.request_failure_code(),
                "WORKER_LOST" | "COORDINATOR_LOST"
            ));
        }
    }

    fn body(instruction: &str, text: &str) -> AnalysisBody {
        AnalysisBody {
            instruction: instruction.to_owned(),
            text: text.to_owned(),
            source_name: None,
            max_output_tokens: None,
            target: None,
        }
    }

    #[test]
    fn bounds_are_checked_before_anything_is_queued() {
        assert!(AnalysisRequest::validate(&body("Summarise it.", "hello")).is_ok());
        assert!(AnalysisRequest::validate(&body("   ", "hello")).is_err());
        assert!(AnalysisRequest::validate(&body("Summarise it.", "   ")).is_err());
        assert!(
            AnalysisRequest::validate(&body("Summarise it.", &"a".repeat(MAX_TEXT_BYTES + 1)))
                .is_err()
        );
        assert!(
            AnalysisRequest::validate(&body(&"a".repeat(MAX_INSTRUCTION_BYTES + 1), "hello"))
                .is_err()
        );

        let mut ceiling = body("Summarise it.", "hello");
        ceiling.max_output_tokens = Some(MAX_OUTPUT_TOKENS + 1);
        assert!(AnalysisRequest::validate(&ceiling).is_err());
        ceiling.max_output_tokens = Some(0);
        assert!(AnalysisRequest::validate(&ceiling).is_err());
        ceiling.max_output_tokens = Some(MAX_OUTPUT_TOKENS);
        assert!(AnalysisRequest::validate(&ceiling).is_ok());
    }

    /// The persisted input describes the document; it is not the document.
    #[test]
    fn the_stored_input_never_carries_the_document() {
        let secret = "the merger closes on Tuesday";
        let request =
            AnalysisRequest::validate(&body("Summarise it.", secret)).expect("valid request");
        let stored = request.redacted_input().to_string();
        assert!(!stored.contains(secret), "{stored}");
        assert!(stored.contains("\"text_bytes\":28"), "{stored}");
    }

    /// Keep the document separate from the owner's instruction in engine messages.
    #[test]
    fn the_document_is_a_user_turn_and_the_instruction_is_the_system_turn() {
        let mut source = body("List the risks.", "Risk one. Risk two.");
        source.source_name = Some("board-notes.txt".into());
        let request = AnalysisRequest::validate(&source).expect("valid request");
        let upstream = request.upstream_body("example/model-32b");

        assert_eq!(upstream["model"], "example/model-32b");
        assert_eq!(upstream["stream"], false);
        assert_eq!(upstream["max_tokens"], DEFAULT_OUTPUT_TOKENS);
        assert_eq!(upstream["messages"][0]["role"], "system");
        assert_eq!(upstream["messages"][0]["content"], "List the risks.");
        assert_eq!(upstream["messages"][1]["role"], "user");
        assert_eq!(
            upstream["messages"][1]["content"],
            "Document: board-notes.txt\n\nRisk one. Risk two."
        );
    }

    #[test]
    fn an_empty_completion_is_not_an_answer() {
        assert_eq!(
            completion_text(&json!({
                "choices": [{ "message": { "content": "Some answer." } }]
            })),
            Some("Some answer.".to_owned())
        );
        assert_eq!(
            completion_text(&json!({ "choices": [{ "message": { "content": "" } }] })),
            None
        );
        assert_eq!(completion_text(&json!({ "choices": [] })), None);
        assert_eq!(completion_text(&json!({})), None);
    }
}
