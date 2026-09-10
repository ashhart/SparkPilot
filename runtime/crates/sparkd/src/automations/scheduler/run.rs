//! One claimed automation: run it, and settle its run row and its durable operation on every exit.

use futures::FutureExt;
use serde_json::{Value, json};
use uuid::Uuid;

use super::store::{self, Automation};
use super::{CANCELLED_CODE, PANICKED_CODE, RunOutcome};
use crate::state::AppState;
use crate::store::StoreError;

/// Run one claimed automation and settle both its run row and its operation, whatever happens.
pub async fn execute(state: &AppState, automation: Automation, run_id: Uuid) {
    execute_with_limit(
        state,
        automation,
        run_id,
        std::time::Duration::from_secs(600),
    )
    .await;
}

pub(super) async fn execute_with_limit(
    state: &AppState,
    automation: Automation,
    run_id: Uuid,
    limit: std::time::Duration,
) {
    let Some(database) = &state.database else {
        return;
    };
    let Some(operation) = operation_of(state, run_id) else {
        settle(
            state,
            run_id,
            "failed",
            None,
            Some("AUTOMATION_RUN_INTERRUPTED"),
            &[],
        );
        return;
    };
    // The run holds a lease for as long as it is working, so a death leaves it to the reaper.
    let lease = match state.jobs.acquire_lease(database.clone(), operation) {
        Ok(lease) => lease,
        Err(crate::jobs::LeaseError::Held) => {
            // A duplicate dispatcher cannot finish a live worker's run, even when cancellation is pending.
            settle_unstarted_cancellation(state, run_id, operation);
            return;
        }
        Err(error) => {
            tracing::warn!(%error, %operation, "an automation run could not take its operation lease");
            return;
        }
    };
    let Some(runner) = state.automations.runner.clone() else {
        let landed = settle_all(
            state,
            run_id,
            lease,
            Settlement::failed("AUTOMATION_RUNNER_UNAVAILABLE"),
        );
        if landed {
            emit_outcome(
                state,
                &automation,
                "failed",
                Some("AUTOMATION_RUNNER_UNAVAILABLE"),
            );
        }
        return;
    };
    if lease.is_cancelled() {
        if settle_all(state, run_id, lease, Settlement::failed(CANCELLED_CODE)) {
            emit_outcome(state, &automation, "failed", Some(CANCELLED_CODE));
        }
        return;
    }
    emit(state, &automation, "automation.run.started", "notice", None);
    // A panic in the model loop is this run's failure, not the scheduler's death.
    let attempt = std::panic::AssertUnwindSafe(runner.run(state, &automation)).catch_unwind();
    tokio::pin!(attempt);
    let deadline = tokio::time::sleep(limit);
    tokio::pin!(deadline);
    let mut cancellation = tokio::time::interval(std::time::Duration::from_millis(250));
    let outcome = loop {
        tokio::select! {
            biased;
            _ = &mut deadline => break Ok(failed_outcome("AUTOMATION_RUN_TIMED_OUT")),
            _ = cancellation.tick() => {
                if lease.is_cancelled() { break Ok(failed_outcome(CANCELLED_CODE)); }
            }
            result = &mut attempt => break result,
        }
    };
    let outcome = match outcome {
        Ok(outcome) => outcome,
        Err(_) => {
            tracing::error!(%run_id, "an automation runner panicked; the run is failed");
            emit(
                state,
                &automation,
                "automation.run.panicked",
                "error",
                Some(PANICKED_CODE),
            );
            RunOutcome {
                text: String::new(),
                error_code: Some(PANICKED_CODE.to_owned()),
                tool_calls: Vec::new(),
            }
        }
    };
    let error_code = if lease.is_cancelled() {
        Some(CANCELLED_CODE.to_owned())
    } else {
        outcome.error_code.clone()
    };
    let settlement = Settlement {
        state: if error_code.is_none() {
            "succeeded"
        } else {
            "failed"
        },
        text: Some(outcome.text.clone()),
        error_code: error_code.clone(),
        tool_calls: outcome.tool_calls.clone(),
    };
    if !settle_all(state, run_id, lease, settlement) {
        return;
    }
    let error_code = store::run(&database.lock(), run_id)
        .ok()
        .flatten()
        .and_then(|run| run.error_code);
    emit_outcome(
        state,
        &automation,
        settlement_state(&error_code),
        error_code.as_deref(),
    );
}

/// The durable operation this run was claimed with.
fn operation_of(state: &AppState, run_id: Uuid) -> Option<Uuid> {
    let conn = state.database.as_ref()?.lock();
    store::run(&conn, run_id)
        .ok()
        .flatten()
        .and_then(|run| run.operation_id)
}

fn failed_outcome(code: &str) -> RunOutcome {
    RunOutcome {
        error_code: Some(code.to_owned()),
        ..RunOutcome::default()
    }
}

fn settle_unstarted_cancellation(state: &AppState, run: Uuid, operation: Uuid) {
    let Some(database) = &state.database else {
        return;
    };
    let conn = database.lock();
    let unstarted = conn
        .query_row(
            "SELECT state = 'cancelling' AND lease_owner IS NULL FROM operations WHERE id = ?1",
            [operation.to_string()],
            |row| row.get::<_, bool>(0),
        )
        .unwrap_or(false);
    if unstarted
        && state
            .jobs
            .cancelled(&conn, operation, CANCELLED_CODE)
            .is_ok()
    {
        let _ = store::finish_run(
            &conn,
            run,
            "failed",
            None,
            Some(CANCELLED_CODE),
            &[],
            state.clock.now().unix_timestamp(),
        );
    }
}

fn settlement_state(error_code: &Option<String>) -> &'static str {
    match error_code.as_deref() {
        None => "succeeded",
        Some(CANCELLED_CODE) => "cancelled",
        Some(_) => "failed",
    }
}

/// What one exit from `execute` writes to the run row and to the operation.
struct Settlement {
    state: &'static str,
    text: Option<String>,
    error_code: Option<String>,
    tool_calls: Vec<Value>,
}

impl Settlement {
    fn failed(error_code: &str) -> Self {
        Self {
            state: "failed",
            text: None,
            error_code: Some(error_code.to_owned()),
            tool_calls: Vec::new(),
        }
    }
}

/// Settle the run row and its operation together; every exit from `execute` comes through here.
fn settle_all(
    state: &AppState,
    run_id: Uuid,
    lease: crate::jobs::OperationLease,
    mut settlement: Settlement,
) -> bool {
    let operation = lease.operation_id();
    let result = json!({"run_id": run_id, "text": settlement.text.as_deref().unwrap_or_default()});
    let landed = match settlement.error_code.as_deref() {
        None => lease.settle_succeeded(&result),
        Some(code) => lease.settle_failed(code),
    };
    if !landed {
        return false;
    }
    // The fenced operation is authoritative, including a cancellation racing the final write.
    let Some(database) = &state.database else {
        return false;
    };
    let conn = database.lock();
    let Ok(Some(row)) = crate::store::operation_row(&conn, operation) else {
        return false;
    };
    settlement.state = if row.state == "succeeded" {
        "succeeded"
    } else {
        "failed"
    };
    settlement.error_code = row.error_code;
    let written = store::finish_run(
        &conn,
        run_id,
        settlement.state,
        settlement.text.as_deref(),
        settlement.error_code.as_deref(),
        &settlement.tool_calls,
        state.clock.now().unix_timestamp(),
    );
    if let Err(error) = written {
        tracing::warn!(%error, "could not settle an automation run after its operation");
        return false;
    };
    true
}

fn emit_outcome(state: &AppState, automation: &Automation, run_state: &str, code: Option<&str>) {
    let (event, severity) = match run_state {
        "succeeded" => ("automation.run.completed", "notice"),
        _ => ("automation.run.failed", "warning"),
    };
    emit(state, automation, event, severity, code);
}

/// One live event per run boundary, carrying no result text.
pub(super) fn emit(
    state: &AppState,
    automation: &Automation,
    event_type: &str,
    severity: &str,
    error_code: Option<&str>,
) {
    let Some(database) = &state.database else {
        return;
    };
    let conn = database.lock();
    emit_on(
        &conn,
        state,
        event_type,
        severity,
        json!({
            "automation_id": automation.id,
            "name": automation.name,
            "web_access": automation.web_access,
            "error_code": error_code,
        }),
    );
}

/// Publish on a connection the caller already holds, so an event can join its own transaction.
pub(super) fn emit_on(
    conn: &rusqlite::Connection,
    state: &AppState,
    event_type: &str,
    severity: &str,
    payload: Value,
) {
    state.events.emit(
        Some(conn),
        &state.identity.node_id().to_string(),
        None,
        event_type,
        severity,
        payload,
    );
}

pub(super) fn settle(
    state: &AppState,
    run_id: Uuid,
    run_state: &str,
    text: Option<&str>,
    error_code: Option<&str>,
    tool_calls: &[Value],
) {
    let Some(database) = &state.database else {
        return;
    };
    let now = state.clock.now().unix_timestamp();
    let conn = database.lock();
    if let Err(error) =
        store::finish_run(&conn, run_id, run_state, text, error_code, tool_calls, now)
    {
        tracing::warn!(%error, "could not record an automation result");
    }
}

pub(super) fn audit(
    conn: &rusqlite::Connection,
    state: &AppState,
    automation: &Automation,
    operation: Option<Uuid>,
    action: &str,
) -> Result<(), StoreError> {
    crate::audit::append(
        conn,
        state.clock.as_ref(),
        &crate::audit::AuditDraft {
            actor_device_id: Some(automation.owner_device_id),
            actor_role: Some("owner"),
            source_route: "/scheduler/automations",
            action,
            resource: Some(&automation.name),
            result: "accepted",
            operation_id: operation,
            request_id: None,
            details: &json!({
                "automation_id": automation.id,
                "web_access": automation.web_access,
                "model_id": automation.model_id,
            }),
        },
    )?;
    Ok(())
}
