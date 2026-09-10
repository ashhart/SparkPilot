//! Persist one-shot owner warmup delegation independently of the app, without replaying a claimed load after crashes.
use std::sync::Arc;

use parking_lot::Mutex;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use tokio::sync::Notify;
use uuid::Uuid;

use crate::preview::PreviewDraft;
use crate::state::AppState;
use crate::store::StoreError;

pub const MIN_LEAD_SECONDS: i64 = 60;
pub const MAX_LEAD_SECONDS: i64 = 7 * 86_400;
pub const GRACE_SECONDS: i64 = 600;
pub const MAX_PENDING: i64 = 8;

#[derive(Clone, Default)]
pub struct WarmupService {
    pub(crate) wake: Arc<Notify>,
    /// Serialises final claim/spawn against disable, never held across await.
    pub(crate) dispatch: Arc<Mutex<()>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WarmupPin {
    pub node_id: Uuid,
    pub model_id: String,
    pub profile_id: String,
    pub recipe_revision: String,
    pub source_revision: String,
    pub recipe_digest: String,
    pub signature_key_id: String,
    pub required_memory_bytes: u64,
    pub system_reserve_bytes: u64,
}

impl WarmupPin {
    pub(crate) fn from_draft(draft: &PreviewDraft) -> Option<Self> {
        let recipe = draft.binding.recipe.as_ref()?;
        Some(Self {
            node_id: draft.binding.target.node_id,
            model_id: recipe.model_id.clone(),
            profile_id: recipe.profile_id.clone()?,
            recipe_revision: recipe.recipe_revision.clone(),
            source_revision: recipe.source_revision.clone(),
            recipe_digest: recipe.recipe_digest.clone(),
            signature_key_id: recipe.signature_key_id.clone(),
            required_memory_bytes: draft.binding.evidence.required_memory_bytes?,
            system_reserve_bytes: draft.binding.evidence.system_reserve_bytes?,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WarmupSchedule {
    pub id: Uuid,
    pub node_id: Uuid,
    pub model_id: String,
    pub profile_id: String,
    pub due_at: i64,
    pub expires_at: i64,
    pub state: String,
    pub result_code: String,
    pub operation_id: Option<Uuid>,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone)]
pub(crate) struct StoredWarmup {
    pub schedule: WarmupSchedule,
    pub owner_device_id: Uuid,
    pub pin: WarmupPin,
}

fn decode<T: serde::de::DeserializeOwned>(raw: String, column: usize) -> rusqlite::Result<T> {
    serde_json::from_str(&raw).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            column,
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })
}

fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredWarmup> {
    fn uuid(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<Uuid> {
        Uuid::parse_str(&row.get::<_, String>(index)?).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                index,
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })
    }
    Ok(StoredWarmup {
        schedule: WarmupSchedule {
            id: uuid(row, 0)?,
            node_id: uuid(row, 1)?,
            model_id: row.get(3)?,
            profile_id: row.get(4)?,
            due_at: row.get(6)?,
            expires_at: row.get(7)?,
            state: row.get(8)?,
            result_code: row.get(9)?,
            operation_id: row
                .get::<_, Option<String>>(10)?
                .map(|raw| {
                    Uuid::parse_str(&raw).map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            10,
                            rusqlite::types::Type::Text,
                            Box::new(error),
                        )
                    })
                })
                .transpose()?,
            created_at: row.get(11)?,
            updated_at: row.get(12)?,
        },
        owner_device_id: uuid(row, 2)?,
        pin: decode(row.get(5)?, 5)?,
    })
}
const COLUMNS: &str = "id,node_id,owner_device_id,model_id,profile_id,pin_json,due_at,expires_at,state,result_code,operation_id,created_at,updated_at";

pub(crate) fn get(conn: &Connection, id: Uuid) -> Result<Option<StoredWarmup>, StoreError> {
    Ok(conn
        .query_row(
            &format!("SELECT {COLUMNS} FROM warmup_schedules WHERE id=?1"),
            [id.to_string()],
            row,
        )
        .optional()?)
}

pub(crate) fn list(conn: &Connection) -> Result<Vec<StoredWarmup>, StoreError> {
    Ok(conn
        .prepare(&format!(
            "SELECT {COLUMNS} FROM warmup_schedules ORDER BY created_at DESC,id LIMIT 136"
        ))?
        .query_map([], row)?
        .collect::<rusqlite::Result<Vec<_>>>()?)
}

pub(crate) fn owner_valid(conn: &Connection, owner: Uuid) -> Result<bool, StoreError> {
    Ok(crate::store::load_device_by_id(conn, &owner)?.is_some_and(|device| device.role == "owner"))
}

pub(crate) fn insert(
    conn: &Connection,
    pin: &WarmupPin,
    owner: Uuid,
    due: i64,
    now: i64,
) -> Result<WarmupSchedule, StoreError> {
    let id = Uuid::new_v4();
    let pin_json =
        serde_json::to_string(pin).map_err(|error| StoreError::Audit(error.to_string()))?;
    conn.execute("INSERT INTO warmup_schedules VALUES (?1,?2,?3,?4,?5,?6,?7,?8,'pending','WARMUP_SCHEDULED',NULL,?9,?9)",
        params![id.to_string(), pin.node_id.to_string(), owner.to_string(), pin.model_id, pin.profile_id, pin_json, due, due+GRACE_SECONDS, now])?;
    // Keep history bounded without deleting an operation or a pending delegation.
    conn.execute("DELETE FROM warmup_schedules WHERE state NOT IN ('pending','dispatching','running') AND id NOT IN
        (SELECT id FROM warmup_schedules WHERE state NOT IN ('pending','dispatching','running') ORDER BY updated_at DESC,id LIMIT 128)", [])?;
    Ok(get(conn, id)?.expect("inserted warm-up").schedule)
}

pub(crate) fn terminal(
    conn: &Connection,
    id: Uuid,
    state: &str,
    code: &str,
    now: i64,
) -> Result<(), StoreError> {
    conn.execute("UPDATE warmup_schedules SET state=?2,result_code=?3,updated_at=?4 WHERE id=?1 AND state IN ('pending','dispatching','running')",
        params![id.to_string(), state, code, now])?;
    Ok(())
}

pub(crate) fn reconcile(conn: &Connection, now: i64, startup: bool) -> Result<(), StoreError> {
    for stored in list(conn)? {
        let schedule = &stored.schedule;
        if schedule.state == "pending" {
            if !owner_valid(conn, stored.owner_device_id)? {
                terminal(conn, schedule.id, "revoked", "WARMUP_OWNER_REVOKED", now)?;
            } else if now > schedule.expires_at {
                terminal(conn, schedule.id, "expired", "WARMUP_WINDOW_MISSED", now)?;
            }
        } else if matches!(schedule.state.as_str(), "dispatching" | "running") {
            let operation = schedule
                .operation_id
                .map(|id| crate::store::operation_row(conn, id))
                .transpose()?
                .flatten();
            match operation.as_ref().map(|operation| operation.state.as_str()) {
                Some("succeeded") => terminal(conn, schedule.id, "succeeded", "WARMUP_READY", now)?,
                Some("failed" | "cancelled") => terminal(
                    conn,
                    schedule.id,
                    "failed",
                    operation
                        .as_ref()
                        .and_then(|operation| operation.error_code.as_deref())
                        .unwrap_or("WARMUP_LOAD_FAILED"),
                    now,
                )?,
                _ if startup => {
                    // No automatic retry of a claim whose side effect is uncertain.
                    terminal(
                        conn,
                        schedule.id,
                        "interrupted",
                        "WARMUP_DISPATCH_INTERRUPTED",
                        now,
                    )?;
                }
                _ => {}
            }
        }
    }
    Ok(())
}

/// Start only after engine/operation startup recovery has completed.
pub fn spawn(state: AppState) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let Some(database) = &state.database else {
            return;
        };
        if let Err(error) = reconcile(&database.lock(), state.clock.now().unix_timestamp(), true) {
            tracing::error!(%error, "warm-up recovery failed; scheduler stopped");
            return;
        }
        loop {
            // Register before reading SQLite so a concurrent insertion cannot be lost.
            let notified = state.warmups.wake.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if let Err(error) = run_due(&state).await {
                tracing::warn!(%error, "warm-up check failed");
                tokio::select! { _ = &mut notified => {}, _ = tokio::time::sleep(std::time::Duration::from_secs(30)) => {} }
                continue;
            }
            let next = {
                let conn = database.lock();
                conn.query_row("SELECT MIN(due_at) FROM warmup_schedules WHERE state='pending'", [], |row| row.get::<_, Option<i64>>(0))
                    .and_then(|next| conn.query_row("SELECT EXISTS(SELECT 1 FROM warmup_schedules WHERE state IN ('dispatching','running'))", [], |row| row.get::<_, bool>(0)).map(|running| (next, running)))
            };
            match next {
                Ok((None, false)) => notified.await,
                Ok((due, running)) => {
                    let seconds = due.map(|due| {
                        due.saturating_sub(state.clock.now().unix_timestamp())
                            .max(1) as u64
                    });
                    // Recheck due schedules after wall-clock corrections; empty or terminal queues wait only for notifications.
                    let seconds = if running {
                        seconds.unwrap_or(5).min(5)
                    } else {
                        seconds.unwrap_or(1).min(60)
                    };
                    tokio::select! { _ = &mut notified => {}, _ = tokio::time::sleep(std::time::Duration::from_secs(seconds)) => {} }
                }
                Err(error) => {
                    tracing::error!(%error, "warm-up storage failed; scheduler stopped");
                    return;
                }
            }
        }
    })
}

/// One bounded pass, also used by deterministic-clock tests.
pub async fn run_due(state: &AppState) -> Result<(), StoreError> {
    let Some(database) = &state.database else {
        return Ok(());
    };
    let now = state.clock.now().unix_timestamp();
    let due = {
        let conn = database.lock();
        reconcile(&conn, now, false)?;
        list(&conn)?
            .into_iter()
            .filter(|stored| stored.schedule.state == "pending" && stored.schedule.due_at <= now)
            .take(MAX_PENDING as usize)
            .collect::<Vec<_>>()
    };
    for stored in due {
        dispatch_one(state, stored).await?;
    }
    Ok(())
}

fn final_pin_refusal(state: &AppState, pin: &WarmupPin) -> Option<&'static str> {
    use spark_telemetry::AdmissionDecision;
    let result = (|| {
        let inventory = state.models.as_ref()?.snapshot();
        let recipe = inventory.recipe(&pin.model_id)?;
        state
            .catalogue_refresh
            .as_ref()?
            .verify_recipe(recipe)
            .ok()?;
        let identity =
            crate::preview::PreviewRecipeIdentity::from_recipe(recipe, Some(&pin.profile_id))
                .ok()?;
        if identity.recipe_digest != pin.recipe_digest
            || identity.source_revision != pin.source_revision
            || identity.signature_key_id != pin.signature_key_id
            || state.identity.node_id() != pin.node_id
        {
            return Some("WARMUP_REVIEW_CHANGED");
        }
        let profile = recipe
            .profiles
            .iter()
            .find(|profile| profile.id == pin.profile_id)?;
        let admission = state
            .engine
            .manager
            .as_ref()?
            .admission_evidence(recipe, profile, false)
            .ok()?;
        match admission.decision {
            AdmissionDecision::DenyInsufficientMemory => return Some("MODEL_INSUFFICIENT_MEMORY"),
            AdmissionDecision::DenyPressureActive => return Some("MEMORY_PRESSURE_ACTIVE"),
            AdmissionDecision::DenyProfileUnsafe => return Some("MODEL_PROFILE_UNSAFE"),
            AdmissionDecision::Allow { .. } => {}
        }
        if admission.required_memory_bytes != pin.required_memory_bytes
            || admission.system_reserve_bytes != pin.system_reserve_bytes
        {
            return Some("WARMUP_REVIEW_CHANGED");
        }
        Some("")
    })();
    match result {
        Some("") => None,
        Some(code) => Some(code),
        None => Some("WARMUP_REVIEW_CHANGED"),
    }
}

async fn dispatch_one(state: &AppState, stored: StoredWarmup) -> Result<(), StoreError> {
    let Some(database) = &state.database else {
        return Ok(());
    };
    let result = crate::warmup_api::live_draft(
        state,
        &stored.schedule.model_id,
        &stored.schedule.profile_id,
    )
    .await;
    let _dispatch = state.warmups.dispatch.lock();
    // After privileged probes, recheck immutable recipe and reviewed budget before SQLite mutation; the engine still owns live admission.
    let changed = final_pin_refusal(state, &stored.pin);
    let now = state.clock.now().unix_timestamp();
    let mut conn = database.lock();
    let tx = conn.transaction()?;
    let Some(current) = get(&tx, stored.schedule.id)? else {
        return Ok(());
    };
    if current.schedule.state != "pending" {
        return Ok(());
    }
    let refusal = if !owner_valid(&tx, current.owner_device_id)? {
        Some(("revoked", "WARMUP_OWNER_REVOKED".to_owned()))
    } else if now > current.schedule.expires_at {
        Some(("expired", "WARMUP_WINDOW_MISSED".to_owned()))
    } else if now < current.schedule.due_at {
        return Ok(());
    } else if let Some(code) = changed {
        Some(("skipped", code.to_owned()))
    } else {
        match &result {
            Err((_, axum::Json(body))) => Some((
                "skipped",
                body.pointer("/error/code")
                    .and_then(|value| value.as_str())
                    .unwrap_or("WARMUP_PRECONDITIONS_UNKNOWN")
                    .to_owned(),
            )),
            Ok((draft, _)) if !draft.blockers.is_empty() => {
                Some(("skipped", draft.blockers[0].code.clone()))
            }
            Ok((draft, _)) if WarmupPin::from_draft(draft).as_ref() != Some(&current.pin) => {
                Some(("skipped", "WARMUP_REVIEW_CHANGED".to_owned()))
            }
            _ => None,
        }
    };
    if let Some((status, code)) = refusal {
        terminal(&tx, current.schedule.id, status, &code, now)?;
        tx.commit()?;
        return Ok(());
    }
    let (_, recipe) = result.expect("validated warm-up draft");
    let operation_id = state.jobs.create(&tx, "model.load", current.owner_device_id, Some(&current.schedule.model_id),
        &serde_json::json!({"model": current.schedule.model_id, "profile": current.schedule.profile_id, "warmup_schedule_id": current.schedule.id}).to_string())?;
    tx.execute("UPDATE warmup_schedules SET state='dispatching',result_code='WARMUP_LOADING',operation_id=?2,updated_at=?3 WHERE id=?1 AND state='pending'",
        params![current.schedule.id.to_string(), operation_id.to_string(), now])?;
    crate::audit::append(
        &tx,
        state.clock.as_ref(),
        &crate::audit::AuditDraft {
            actor_device_id: Some(current.owner_device_id),
            actor_role: Some("owner"),
            source_route: "/scheduler/warmup",
            action: "warmup.dispatch",
            resource: Some(&current.schedule.model_id),
            result: "accepted",
            operation_id: Some(operation_id),
            request_id: None,
            details: &serde_json::json!({"schedule_id": current.schedule.id, "profile_id": current.schedule.profile_id}),
        },
    )?;
    tx.commit()?;
    drop(conn);
    // Use ordinary engine admission with replacement always false, so an intervening load can only refuse the scheduled one.
    let manager = state
        .engine
        .manager
        .as_ref()
        .expect("live draft requires engine");
    match manager.spawn_load(operation_id, &recipe, &current.schedule.profile_id, false) {
        Ok(()) => {
            database.lock().execute(
                "UPDATE warmup_schedules SET state='running' WHERE id=?1 AND state='dispatching'",
                [current.schedule.id.to_string()],
            )?;
        }
        Err(error) => {
            let conn = database.lock();
            state.jobs.fail(&conn, operation_id, error.code())?;
            terminal(&conn, current.schedule.id, "skipped", error.code(), now)?;
        }
    }
    Ok(())
}
