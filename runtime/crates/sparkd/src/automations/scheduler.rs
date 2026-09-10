//! Fire each automation once per slot, on the daemon clock, whatever the phone is doing.

use std::sync::Arc;

use futures::FutureExt;
use parking_lot::Mutex;
use serde_json::{Value, json};
use tokio::sync::Notify;
use uuid::Uuid;

use super::store::{self, Automation, MISSED_GRACE_SECONDS};
use crate::state::AppState;
use crate::store::StoreError;

/// The durable operation kind every run is settled through.
pub const RUN_KIND: &str = "automation.run";
/// At most this many automations are dispatched in one pass.
pub const MAX_PER_PASS: usize = 4;
/// The run outcome when the owner cancelled the operation behind it.
pub const CANCELLED_CODE: &str = "OPERATION_CANCELLED";
/// The run outcome when the model loop panicked; the scheduler survives it.
pub const PANICKED_CODE: &str = "AUTOMATION_RUN_PANICKED";
/// How long a panicked scheduler waits before it is started again.
const RESTART_DELAY: std::time::Duration = std::time::Duration::from_secs(5);

/// What one run produced, whoever produced it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RunOutcome {
    pub text: String,
    pub error_code: Option<String>,
    pub tool_calls: Vec<Value>,
}

/// The seam between the schedule and the model, so firing can be proved without an engine.
#[async_trait::async_trait]
pub trait AutomationRunner: Send + Sync + std::fmt::Debug {
    async fn run(&self, state: &AppState, automation: &Automation) -> RunOutcome;
}

#[derive(Clone, Default, Debug)]
pub struct AutomationService {
    pub wake: Arc<Notify>,
    /// Serialises the durable claim against edits and deletions; never held across an await.
    pub dispatch: Arc<Mutex<()>>,
    /// Absent until an engine is available; a pass with no runner does nothing.
    pub runner: Option<Arc<dyn AutomationRunner>>,
}

impl AutomationService {
    pub fn with_runner(runner: Arc<dyn AutomationRunner>) -> Self {
        Self {
            runner: Some(runner),
            ..Self::default()
        }
    }
}

/// Settle runs left behind by a restart before anything new is dispatched.
pub fn reconcile(conn: &rusqlite::Connection, now: i64, startup: bool) -> Result<(), StoreError> {
    for automation in store::list(conn)? {
        for run in store::runs(conn, automation.id)? {
            if run.state != "running" {
                continue;
            }
            let operation = run
                .operation_id
                .map(|id| crate::store::operation_row(conn, id))
                .transpose()?
                .flatten();
            match operation.as_ref().map(|row| row.state.as_str()) {
                Some("succeeded") => {
                    store::finish_run(conn, run.id, "succeeded", None, None, &[], now)?;
                }
                Some("failed" | "cancelled") => {
                    let code = operation
                        .as_ref()
                        .and_then(|row| row.error_code.as_deref())
                        .unwrap_or("AUTOMATION_RUN_FAILED");
                    store::finish_run(conn, run.id, "failed", None, Some(code), &[], now)?;
                }
                _ if startup => {
                    // A run whose side effect is uncertain is never replayed.
                    store::finish_run(
                        conn,
                        run.id,
                        "interrupted",
                        None,
                        Some("AUTOMATION_RUN_INTERRUPTED"),
                        &[],
                        now,
                    )?;
                }
                _ => {}
            }
        }
    }
    Ok(())
}

/// One bounded pass. The daemon loop and the tests both drive exactly this.
pub async fn run_due(state: &AppState) -> Result<(), StoreError> {
    let Some(database) = &state.database else {
        return Ok(());
    };
    let now = state.clock.now().unix_timestamp();
    let due = {
        let conn = database.lock();
        reconcile(&conn, now, false)?;
        store::list(&conn)?
            .into_iter()
            .filter(|automation| {
                automation.enabled && automation.next_run_at.is_some_and(|slot| slot <= now)
            })
            .take(MAX_PER_PASS)
            .collect::<Vec<_>>()
    };
    for automation in due {
        if let Some((run_id, current)) = claim(state, automation.id, now)? {
            let name = current.name.clone();
            let attempt = std::panic::AssertUnwindSafe(execute(state, current, run_id))
                .catch_unwind()
                .await;
            if attempt.is_err() {
                // `execute` settles its own panics; this is the backstop for one that escapes it.
                tracing::error!(%run_id, name, "an automation run panicked outside its runner");
                settle(state, run_id, "failed", None, Some(PANICKED_CODE), &[]);
            }
        }
    }
    Ok(())
}

/// Claim one slot durably, or discover that another instance already did.
fn claim(state: &AppState, id: Uuid, now: i64) -> Result<Option<(Uuid, Automation)>, StoreError> {
    let Some(database) = &state.database else {
        return Ok(None);
    };
    let _dispatch = state.automations.dispatch.lock();
    let mut conn = database.lock();
    let transaction = conn.transaction()?;
    let Some(current) = store::get(&transaction, id)? else {
        return Ok(None);
    };
    let Some(slot) = current
        .next_run_at
        .filter(|slot| *slot <= now && current.enabled)
    else {
        return Ok(None);
    };
    // A clock that jumped forward is not a backlog to walk: resume at the first slot after now.
    let missed = now - slot > MISSED_GRACE_SECONDS;
    let resume_after = if missed { now } else { slot };
    let following = store::next_slot(
        &current.schedule_expression,
        &current.timezone,
        resume_after,
    )
    .ok();
    let advanced = transaction.execute(
        "UPDATE automations SET next_run_at=?2 WHERE id=?1 AND next_run_at=?3",
        rusqlite::params![id.to_string(), following.flatten(), slot],
    )?;
    if advanced == 0 {
        // Another instance moved the same claim first.
        return Ok(None);
    }
    if missed {
        let (count, at_limit) =
            store::missed_slots(&current.schedule_expression, &current.timezone, slot, now);
        store::record_skipped(&transaction, id, slot, now, "AUTOMATION_SLOT_MISSED")?;
        emit_on(
            &transaction,
            state,
            "automation.slots.missed",
            "warning",
            json!({
                "automation_id": current.id,
                "name": current.name,
                "missed": count,
                "counted_to_limit": at_limit,
                "first_missed_slot": slot,
                "resumes_at": following.flatten(),
            }),
        );
        transaction.commit()?;
        return Ok(None);
    }
    let Some(run_id) = store::claim_run(&transaction, id, "schedule", Some(slot), now)? else {
        // A manual run of the same automation holds the only in-flight slot there is.
        store::record_skipped(&transaction, id, slot, now, "AUTOMATION_RUN_IN_FLIGHT")?;
        transaction.commit()?;
        return Ok(None);
    };
    let operation = state.jobs.create(
        &transaction,
        RUN_KIND,
        current.owner_device_id,
        Some(&current.name),
        &json!({"automation_id": id, "run_id": run_id, "trigger": "schedule", "notify": current.notify}).to_string(),
    )?;
    store::attach_operation(&transaction, run_id, operation)?;
    audit(
        &transaction,
        state,
        &current,
        Some(operation),
        "automation.run.dispatched",
    )?;
    transaction.commit()?;
    Ok(Some((run_id, current)))
}

/// Start after operation recovery, so a restart settles before anything new fires.
pub fn spawn(state: AppState) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let Some(database) = state.database.clone() else {
            return;
        };
        if let Err(error) = reconcile(&database.lock(), state.clock.now().unix_timestamp(), true) {
            tracing::error!(%error, "automation recovery failed; scheduler stopped");
            return;
        }
        // One panic must not silence every automation for the life of the process.
        loop {
            let attempt = std::panic::AssertUnwindSafe(scheduler_loop(&state))
                .catch_unwind()
                .await;
            if attempt.is_ok() {
                return;
            }
            tracing::error!("the automation scheduler panicked; restarting it");
            tokio::time::sleep(RESTART_DELAY).await;
        }
    })
}

/// The scheduler's own loop; it returns only when storage stops answering.
async fn scheduler_loop(state: &AppState) {
    let Some(database) = state.database.clone() else {
        return;
    };
    loop {
        let notified = state.automations.wake.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        if let Err(error) = run_due(state).await {
            tracing::warn!(%error, "automation check failed");
        }
        let next = {
            let conn = database.lock();
            conn.query_row(
                "SELECT MIN(next_run_at) FROM automations WHERE enabled=1 AND next_run_at IS NOT NULL",
                [],
                |row| row.get::<_, Option<i64>>(0),
            )
        };
        let seconds = match next {
            Ok(Some(slot)) => (slot - state.clock.now().unix_timestamp()).clamp(1, 60) as u64,
            Ok(None) => 60,
            Err(error) => {
                tracing::error!(%error, "automation storage failed; scheduler stopped");
                return;
            }
        };
        tokio::select! {
            _ = &mut notified => {},
            _ = tokio::time::sleep(std::time::Duration::from_secs(seconds)) => {}
        }
    }
}

#[path = "scheduler/run.rs"]
mod run;
pub use run::execute;
use run::{audit, emit_on, settle};

#[cfg(test)]
#[path = "scheduler/tests.rs"]
mod tests;
