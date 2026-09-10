//! Build one run's web session from the owner's settings, ask the model, and audit every call it made.

use std::sync::Arc;

use serde_json::json;

use super::scheduler::{AutomationRunner, RunOutcome};
use super::store::Automation;
use crate::state::AppState;
use crate::web_tools::backend::WebAccessSettings;
use crate::web_tools::guard::SystemResolver;
use crate::web_tools::ledger::{CallLedger, HOUR_SECONDS};
use crate::web_tools::outbound::OwnNames;
use crate::web_tools::policy::{self, Surface};
use crate::web_tools::session::{MAX_CALLS_PER_HOUR, Session, ToolCallRecord, WebTransport};
use crate::web_tools::tool_loop::{self, Answer, ModelChat};

/// The instruction an automation's own turn carries, ahead of the tool contract.
const AUTOMATION_FRAMING: &str = "You are performing a scheduled task for the owner of this Spark. Answer with the finished result only, in plain prose, ready to read on a phone. Do not describe your process.";

/// Who asked for this run, so an audit row names the actual caller rather than assuming the owner.
#[derive(Debug, Clone)]
pub struct WebActor {
    pub device_id: Option<uuid::Uuid>,
    pub role: String,
}

impl WebActor {
    /// A scheduled automation is the owner's own standing instruction, with no device behind it.
    pub fn schedule() -> Self {
        Self {
            device_id: None,
            role: "owner".to_owned(),
        }
    }

    /// A request made by a paired device, whatever its role.
    pub fn principal(principal: &crate::auth::Principal) -> Self {
        Self {
            device_id: Some(principal.device_id),
            role: principal.role.clone(),
        }
    }
}

/// The runner used in production: this Spark's own engine and a bounded HTTP client.
#[derive(Debug)]
pub struct LiveRunner;

#[async_trait::async_trait]
impl AutomationRunner for LiveRunner {
    async fn run(&self, state: &AppState, automation: &Automation) -> RunOutcome {
        if let Err(code) = super::model_readiness::prepare(state, automation).await {
            return RunOutcome {
                text: match code {
                    "AUTOMATION_MODEL_BUSY" => "Another model is in use; choose that model for this task or try again after it stops.",
                    "AUTOMATION_MODEL_LOAD_TIMEOUT" => "Your model is still starting; check Models before trying this task again.",
                    _ => "Your Spark could not prepare this model; open Models to check that it is installed and ready.",
                }.to_owned(),
                error_code: Some(code.to_owned()), tool_calls: Vec::new(),
            };
        }
        let settings = settings_for(state, automation);
        match answer(
            state,
            settings,
            Surface::Automation,
            WebActor::schedule(),
            &automation.model_id,
            Some(AUTOMATION_FRAMING),
            vec![json!({"role": "user", "content": automation.instructions})],
        )
        .await
        {
            Ok(answer) => RunOutcome {
                text: answer.text,
                error_code: answer.error_code,
                tool_calls: answer
                    .records
                    .iter()
                    .map(|record| record.to_json())
                    .collect(),
            },
            Err(code) => RunOutcome {
                text: tool_loop::stopped_text(code).to_owned(),
                error_code: Some(code.to_owned()),
                tool_calls: Vec::new(),
            },
        }
    }
}

/// An automation that was not opted in reaches nothing, whatever the Spark's policy says.
fn settings_for(state: &AppState, automation: &Automation) -> WebAccessSettings {
    let stored = crate::automations_api::web_settings::load(state);
    if automation.web_access {
        stored
    } else {
        WebAccessSettings {
            policy: crate::web_tools::policy::WebAccessPolicy::Off,
            ..stored
        }
    }
}

/// Run one bounded conversation with the web tools available, and audit what left the Spark.
pub async fn answer(
    state: &AppState,
    settings: WebAccessSettings,
    surface: Surface,
    actor: WebActor,
    model: &str,
    system_instruction: Option<&str>,
    conversation: Vec<serde_json::Value>,
) -> Result<Answer, &'static str> {
    let Some(transport) = crate::web_tools::live::live_transport() else {
        return Err("WEB_RUN_MODEL_FAILED");
    };
    let chat: Arc<dyn ModelChat> =
        Arc::new(crate::web_tools::live::LoopbackModel::new(state.clone()));
    let secret = crate::automations_api::web_settings::secret(state, &settings);
    let permitted = policy::permits(&settings, surface).is_ok();
    let backend_host = crate::web_tools::backend::backend_host(&settings);
    let ledger = Arc::new(DatabaseLedger {
        state: state.clone(),
        surface,
        permitted,
        actor,
        backend_host,
    });
    let allowance = remaining_hourly_allowance(calls_in_the_last_hour(state));
    let mut session = Session::new(
        settings,
        surface,
        secret,
        OwnNames {
            node_id: state.identity.node_id().to_string(),
            hostname: state.config.node_name.clone(),
        },
        Arc::new(SystemResolver),
        Arc::clone(&transport) as Arc<dyn WebTransport>,
        state.clock.clone(),
    )
    .with_call_ledger(ledger as Arc<dyn CallLedger>, MAX_CALLS_PER_HOUR)
    .with_hourly_allowance(allowance);
    // Every row is written to the audit chain by the ledger as its call ends, not after the run.
    let answer = tool_loop::run(
        chat.as_ref(),
        &mut session,
        model,
        system_instruction,
        conversation,
    )
    .await;
    Ok(answer)
}

/// What is left of the rolling-hour ceiling; per-run budgets alone leave a minutely schedule unbounded.
fn remaining_hourly_allowance(already_made: usize) -> usize {
    MAX_CALLS_PER_HOUR.saturating_sub(already_made)
}

/// Count the places already taken in the rolling hour, so a run starts knowing what is left.
fn calls_in_the_last_hour(state: &AppState) -> usize {
    let Some(database) = &state.database else {
        return MAX_CALLS_PER_HOUR;
    };
    let since = state.clock.now().unix_timestamp() - HOUR_SECONDS;
    let conn = database.lock();
    conn.query_row(
        "SELECT COUNT(*) FROM web_call_reservations WHERE made_at >= ?1",
        rusqlite::params![since],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count.max(0) as usize)
    .unwrap_or(MAX_CALLS_PER_HOUR)
}

/// The Spark's own ledger: a durable place in the hour before a request, an audit row after it.
struct DatabaseLedger {
    state: AppState,
    surface: Surface,
    permitted: bool,
    actor: WebActor,
    backend_host: Option<String>,
}

impl CallLedger for DatabaseLedger {
    /// One immediate transaction, so two runs starting together cannot both read the same count.
    fn reserve(&self, ceiling: usize, now: i64) -> bool {
        let Some(database) = &self.state.database else {
            return false;
        };
        let mut connection = database.lock();
        let Ok(transaction) =
            connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        else {
            return false;
        };
        let taken = transaction
            .execute(
                "DELETE FROM web_call_reservations WHERE made_at < ?1",
                rusqlite::params![now - HOUR_SECONDS],
            )
            .and_then(|_| {
                transaction.query_row("SELECT COUNT(*) FROM web_call_reservations", [], |row| {
                    row.get::<_, i64>(0)
                })
            });
        let Ok(used) = taken else {
            return false;
        };
        if used.max(0) as usize >= ceiling {
            return false;
        }
        let inserted = transaction.execute(
            "INSERT INTO web_call_reservations (made_at) VALUES (?1)",
            rusqlite::params![now],
        );
        inserted.is_ok() && transaction.commit().is_ok()
    }

    fn append(&self, record: &ToolCallRecord) {
        let Some(database) = &self.state.database else {
            return;
        };
        let entry = audit_entry(
            record,
            self.surface,
            self.permitted,
            &self.actor,
            self.backend_host.as_deref(),
        );
        let draft = crate::audit::AuditDraft {
            actor_device_id: entry.actor_device_id,
            actor_role: Some(entry.actor_role.as_str()),
            source_route: "/web-tools",
            action: entry.action,
            resource: entry.resource.as_deref(),
            result: entry.result,
            operation_id: None,
            request_id: None,
            details: &entry.details,
        };
        if let Err(error) =
            crate::audit::append_committed(database, self.state.clock.as_ref(), &draft)
        {
            tracing::error!(%error, "a web tool call could not be audited");
        }
    }
}

/// What one tool call becomes in the audit chain, decided without a database so it can be proved.
struct WebAuditEntry {
    action: &'static str,
    result: &'static str,
    resource: Option<String>,
    actor_device_id: Option<uuid::Uuid>,
    actor_role: String,
    details: serde_json::Value,
}

fn audit_entry(
    record: &crate::web_tools::session::ToolCallRecord,
    surface: Surface,
    permitted: bool,
    actor: &WebActor,
    backend_host: Option<&str>,
) -> WebAuditEntry {
    let action = match (record.tool.as_str(), record.outcome.as_str()) {
        ("personal_context", _) => "web.personal_context.stripped",
        (_, "robots_checked") => "web.robots.checked",
        ("web_search", "succeeded") => "web.search.performed",
        ("web_search", _) => "web.search.refused",
        (_, "succeeded") => "web.fetch.performed",
        _ => "web.fetch.refused",
    };
    WebAuditEntry {
        action,
        result: match record.outcome.as_str() {
            "succeeded" | "robots_checked" | "stripped" => "accepted",
            _ => "refused",
        },
        resource: record.url.clone().or_else(|| record.query.clone()),
        actor_device_id: actor.device_id,
        actor_role: actor.role.clone(),
        details: json!({
            "surface": surface.name(),
            "policy_permitted": permitted,
            "query": record.query,
            "url": record.url,
            "backend_host": backend_host,
            "bytes": record.result_bytes,
            "error_code": record.error_code,
            "duration_ms": record.duration_ms,
        }),
    }
}

#[cfg(test)]
#[path = "runner/tests.rs"]
mod tests;
