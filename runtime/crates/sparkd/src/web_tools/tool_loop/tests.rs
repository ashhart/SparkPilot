use super::*;
use crate::clock::ManualUtcClock;
use crate::web_tools::backend::{SearchBackend, WebAccessSettings};
use crate::web_tools::guard::{HostResolver, ResolveFailed};
use crate::web_tools::outbound::OwnNames;
use crate::web_tools::policy::{Surface, WebAccessPolicy};
use crate::web_tools::session::{TransportRequest, TransportResponse, WebTransport};
use parking_lot::Mutex;
use std::net::IpAddr;
use std::sync::Arc;

struct Resolver;

impl HostResolver for Resolver {
    fn resolve(&self, _host: &str) -> Result<Vec<IpAddr>, ResolveFailed> {
        Ok(vec!["93.184.216.34".parse().expect("address")])
    }
}

/// Answers every request with the same page, so the loop's behaviour is the only variable.
struct Pages;

#[async_trait::async_trait]
impl WebTransport for Pages {
    async fn get(&self, request: &TransportRequest) -> Result<TransportResponse, String> {
        Ok(TransportResponse {
            status: 200,
            location: None,
            content_type: "text/html".to_owned(),
            body: format!("<title>Page</title><p>Content of {}</p>", request.url),
            bytes: 64,
        })
    }
}

/// Replays a fixed script of model turns and records what it was asked.
struct ScriptedModel {
    turns: Mutex<Vec<Value>>,
    seen: Mutex<Vec<Vec<Value>>>,
}

impl ScriptedModel {
    fn new(turns: Vec<Value>) -> Arc<Self> {
        Arc::new(Self {
            turns: Mutex::new(turns),
            seen: Mutex::new(Vec::new()),
        })
    }

    fn last_conversation(&self) -> Vec<Value> {
        self.seen.lock().last().cloned().unwrap_or_default()
    }
}

#[async_trait::async_trait]
impl ModelChat for ScriptedModel {
    async fn complete(
        &self,
        _model: &str,
        messages: &[Value],
        _tools: &Value,
    ) -> Result<Value, String> {
        self.seen.lock().push(messages.to_vec());
        let mut turns = self.turns.lock();
        if turns.is_empty() {
            return Ok(json!({"content": "I have nothing further."}));
        }
        Ok(turns.remove(0))
    }
}

fn said(text: &str) -> Value {
    json!({"content": text})
}

fn session() -> Session {
    Session::new(
        WebAccessSettings {
            backend: SearchBackend::DuckDuckGo,
            policy: WebAccessPolicy::AutomationsAndChats,
            ..WebAccessSettings::default()
        },
        Surface::Automation,
        None,
        OwnNames {
            node_id: "6f2c1a44-9c1e-4a3b-8f10-2b7d5e9a0c31".to_owned(),
            hostname: "spark-01".to_owned(),
        },
        Arc::new(Resolver),
        Arc::new(Pages),
        Arc::new(ManualUtcClock::new(
            time::OffsetDateTime::from_unix_timestamp(1_780_000_000).expect("in range"),
        )),
    )
}

#[test]
fn a_fenced_object_only_executes_when_it_is_the_entire_response() {
    let message =
        said("Let me look that up.\n```json\n{\"tool\":\"web_search\",\"query\":\"uk news\"}\n```");
    assert_eq!(
        parse_tool_call(&message),
        None,
        "prose may quote an example; it is not an instruction"
    );
    let standalone = said("```json\n{\"tool\":\"web_search\",\"query\":\"uk news\"}\n```");
    assert_eq!(
        parse_tool_call(&standalone),
        Some(ToolCall::Search {
            query: "uk news".into()
        })
    );
}

#[test]
fn a_native_tool_call_is_read_when_the_engine_produces_one() {
    let message = json!({
        "content": null,
        "tool_calls": [{
            "id": "call_1",
            "type": "function",
            "function": {"name": "web_fetch", "arguments": "{\"url\":\"https://news.example/one\"}"}
        }]
    });
    assert_eq!(
        parse_tool_call(&message),
        Some(ToolCall::Fetch {
            url: "https://news.example/one".to_owned()
        })
    );
}

#[test]
fn an_answer_that_merely_mentions_json_is_not_a_tool_call() {
    assert_eq!(
        parse_tool_call(&said("The result was {} and nothing else.")),
        None
    );
    assert_eq!(
        parse_tool_call(&said("Here is the news in plain words.")),
        None
    );
    assert_eq!(
        parse_tool_call(&said("{\"tool\":\"shell\",\"command\":\"rm -rf /\"}")),
        None,
        "a tool the runtime does not have was accepted"
    );
}

#[tokio::test]
async fn the_loop_runs_what_the_model_asks_for_and_stops_when_it_answers() {
    let model = ScriptedModel::new(vec![
        said("{\"tool\":\"web_search\",\"query\":\"uk news\"}"),
        said("{\"tool\":\"web_fetch\",\"url\":\"https://news.example/one\"}"),
        said("Here is what the papers say today."),
    ]);
    let mut session = session();
    let answer = run(
        model.as_ref(),
        &mut session,
        "a-model",
        None,
        vec![json!({"role":"user","content":"brief me"})],
    )
    .await;
    assert_eq!(answer.text, "Here is what the papers say today.");
    assert!(!answer.truncated);
    assert_eq!(answer.error_code, None);
    // The search, the robots check the fetch had to make first, and the fetch itself.
    assert_eq!(answer.records.len(), 3);
    assert_eq!(answer.records[0].tool, "web_search");
    assert_eq!(answer.records[1].outcome, "robots_checked");
    assert_eq!(answer.records[2].tool, "web_fetch");
    assert_eq!(answer.sources.len(), 1);
}

#[tokio::test]
async fn every_tool_result_reaches_the_model_labelled_as_untrusted() {
    let model = ScriptedModel::new(vec![
        said("{\"tool\":\"web_fetch\",\"url\":\"https://news.example/one\"}"),
        said("Read and summarised."),
    ]);
    let mut session = session();
    run(
        model.as_ref(),
        &mut session,
        "a-model",
        None,
        vec![json!({"role":"user","content":"read it"})],
    )
    .await;
    let conversation = model.last_conversation();
    let quoted = conversation
        .iter()
        .filter(|turn| {
            turn["content"]
                .as_str()
                .is_some_and(|value| value.contains("<untrusted>"))
        })
        .count();
    assert_eq!(quoted, 1, "the page was not quoted as untrusted data");
    assert!(
        conversation[0]["content"]
            .as_str()
            .is_some_and(|value| value.contains("UNTRUSTED DATA")),
        "the system turn was not re-sent with the run"
    );
}

#[tokio::test]
async fn a_model_that_never_stops_asking_is_stopped_with_plain_words() {
    let turns = vec![said("{\"tool\":\"web_search\",\"query\":\"uk news\"}"); 20];
    let model = ScriptedModel::new(turns);
    let mut session = session();
    let answer = run(
        model.as_ref(),
        &mut session,
        "a-model",
        None,
        vec![json!({"role":"user","content":"go"})],
    )
    .await;
    assert!(answer.truncated);
    assert_eq!(answer.error_code.as_deref(), Some("WEB_TOOL_CALL_LIMIT"));
    assert_eq!(answer.records.len(), MAX_TOOL_CALLS);
    assert!(answer.text.contains("stopped"), "{}", answer.text);
}

#[tokio::test]
async fn the_owners_own_framing_never_replaces_the_untrusted_content_rule() {
    let model = ScriptedModel::new(vec![said("Done.")]);
    let mut session = session();
    run(
        model.as_ref(),
        &mut session,
        "a-model",
        Some("Answer as a morning brief."),
        vec![json!({"role":"user","content":"go"})],
    )
    .await;
    let system = model.last_conversation()[0]["content"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    assert!(system.starts_with("Answer as a morning brief."), "{system}");
    assert!(system.contains(TOOL_CONTRACT), "{system}");
}

#[tokio::test]
async fn a_model_that_cannot_be_reached_leaves_a_named_failure() {
    struct Dead;
    #[async_trait::async_trait]
    impl ModelChat for Dead {
        async fn complete(&self, _: &str, _: &[Value], _: &Value) -> Result<Value, String> {
            Err("upstream unreachable".to_owned())
        }
    }
    let mut session = session();
    let answer = run(
        &Dead,
        &mut session,
        "a-model",
        None,
        vec![json!({"role":"user","content":"go"})],
    )
    .await;
    assert_eq!(answer.error_code.as_deref(), Some("WEB_RUN_MODEL_FAILED"));
    assert!(answer.text.contains("did not answer"), "{}", answer.text);
}

/// BH-36: the calendar block the app puts in the system message never reaches the model input.
#[tokio::test]
async fn the_owners_personal_context_never_reaches_the_tool_loop() {
    let calendar = "<personal_context>\nevent Fri 2026-09-05 19:00 Dinner at 21 Rue Blanche\n</personal_context>";
    let model = ScriptedModel::new(vec![said("Nothing to look up.")]);
    let mut session = session();
    let answer = run(
        model.as_ref(),
        &mut session,
        "llama",
        Some(&format!("You are helping the owner.\n\n{calendar}")),
        vec![json!({"role": "user", "content": format!("plan around {calendar}")})],
    )
    .await;
    let seen = serde_json::to_string(&model.last_conversation()).expect("json");
    assert!(!seen.contains("personal_context"), "{seen}");
    assert!(!seen.contains("Rue Blanche"), "{seen}");
    assert!(seen.contains("You are helping the owner."), "{seen}");
    let stripped = answer
        .records
        .iter()
        .find(|record| record.tool == "personal_context")
        .expect("the run records that the block was taken out");
    assert_eq!(stripped.outcome, "stripped");
}

/// BH-36: a run with nothing personal in it records no removal.
#[tokio::test]
async fn a_run_with_no_personal_context_records_no_removal() {
    let model = ScriptedModel::new(vec![said("Nothing to look up.")]);
    let mut session = session();
    let answer = run(
        model.as_ref(),
        &mut session,
        "llama",
        Some("be brief"),
        vec![json!({"role": "user", "content": "what is the weather"})],
    )
    .await;
    assert!(answer.records.is_empty());
}

#[test]
fn a_quoted_tool_example_cannot_start_a_request() {
    assert!(
        parse_tool_call(&said(
            "Example: {\"tool\":\"web_search\",\"query\":\"weather\"}. Do not run it."
        ))
        .is_none()
    );
}

#[tokio::test]
async fn model_time_is_part_of_the_run_deadline_even_for_a_final_answer() {
    struct Slow(Arc<ManualUtcClock>);
    #[async_trait::async_trait]
    impl ModelChat for Slow {
        async fn complete(&self, _: &str, _: &[Value], _: &Value) -> Result<Value, String> {
            self.0.advance(time::Duration::seconds(181));
            Ok(said("Finished"))
        }
    }
    let clock = Arc::new(ManualUtcClock::new(time::OffsetDateTime::UNIX_EPOCH));
    let mut session = Session::new(
        WebAccessSettings::default(),
        Surface::Automation,
        None,
        OwnNames {
            node_id: "audit".into(),
            hostname: "audit".into(),
        },
        Arc::new(Resolver),
        Arc::new(Pages),
        clock.clone(),
    );
    let answer = run(&Slow(clock), &mut session, "model", None, vec![]).await;
    assert_eq!(answer.error_code.as_deref(), Some("WEB_RUN_TIME_LIMIT"));
}
