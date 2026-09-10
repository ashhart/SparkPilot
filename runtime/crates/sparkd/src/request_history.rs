//! Store content-free fixed-target attempts only; cancellation proves proxy disconnect, not engine termination.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Instant;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::{Extension, Json};
use parking_lot::Mutex;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::watch;
use uuid::Uuid;

use crate::auth::Principal;
use crate::capability::Capability;
use crate::idempotency::{IdempotencyRequest, StoredResponse};
use crate::state::AppState;

pub const RETENTION_SECONDS: i64 = 30 * 86_400;
pub const MAX_RECORDS: usize = 2_000;
const MAX_PAGE: usize = 200;
type Error = (StatusCode, Json<Value>);
type CancelWait = Pin<Box<dyn Future<Output = ()> + Send>>;

#[derive(Default)]
pub struct RequestHistoryService {
    active: Mutex<HashMap<Uuid, watch::Sender<bool>>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DeploymentEvidence {
    pub recipe_digest: String,
    pub recipe_revision: String,
    pub source_revision: String,
    pub engine_recipe: String,
    pub engine_image: String,
    pub context_length: Option<u64>,
    pub max_sequences: Option<u32>,
    pub runtime_version: String,
    // Record the admitted recipe identity without claiming independent attestation of model bytes, driver, tokenizer or template.
    pub verification: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestRecord {
    pub attempt_id: String,
    pub request_id: String,
    pub caller_device_id: String,
    pub node_id: String,
    pub model_id: String,
    pub profile_id: Option<String>,
    pub started_at: i64,
    pub finished_at: Option<i64>,
    pub outcome: String,
    pub failure_code: Option<String>,
    pub admission_ms: f64,
    pub first_frame_ms: Option<f64>,
    pub elapsed_ms: Option<f64>,
    pub prompt_tokens: Option<u64>,
    pub completion_tokens: Option<u64>,
    pub provenance: Option<DeploymentEvidence>,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HistoryQuery {
    pub model_id: Option<String>,
    pub attempt_id: Option<Uuid>,
    pub outcome: Option<String>,
    pub after: Option<i64>,
    pub before: Option<i64>,
    pub limit: Option<usize>,
    #[serde(default)]
    pub all_callers: bool,
}

impl HistoryQuery {
    fn validate(&self) -> Result<(), Error> {
        if self.limit.is_some_and(|v| v == 0 || v > MAX_PAGE)
            || self.model_id.as_ref().is_some_and(|v| v.len() > 512)
            || self.outcome.as_ref().is_some_and(|v| {
                ![
                    "running",
                    "succeeded",
                    "failed",
                    "incomplete",
                    "cancelled_unconfirmed",
                    "interrupted_unknown",
                ]
                .contains(&v.as_str())
            })
            || matches!((self.after,self.before),(Some(a),Some(b)) if a>b)
        {
            return Err(error(
                StatusCode::BAD_REQUEST,
                "INVALID_HISTORY_FILTER",
                "The history filter is invalid.",
            ));
        }
        Ok(())
    }
}

fn error(status: StatusCode, code: &str, message: &str) -> Error {
    (
        status,
        Json(
            json!({"error":{"code":code,"message":message,"request_id":crate::route::current_request_id()}}),
        ),
    )
}

fn storage_error(_: impl std::fmt::Display) -> Error {
    error(
        StatusCode::SERVICE_UNAVAILABLE,
        "HISTORY_UNAVAILABLE",
        "Request history is unavailable.",
    )
}

/// Mark in-flight history unknown before serving after restart because prior engine completion cannot be proven.
pub fn recover(conn: &Connection, now: i64) -> rusqlite::Result<()> {
    conn.execute("UPDATE inference_requests SET outcome='interrupted_unknown', finished_at=?1, failure_code='RUNTIME_RESTARTED' WHERE outcome='running'", [now])?;
    prune(conn, now)
}

pub fn prune(conn: &Connection, now: i64) -> rusqlite::Result<()> {
    conn.execute(
        "DELETE FROM inference_requests WHERE outcome != 'running' AND started_at < ?1",
        [now.saturating_sub(RETENTION_SECONDS)],
    )?;
    conn.execute("DELETE FROM inference_requests WHERE attempt_id IN (SELECT attempt_id FROM inference_requests WHERE outcome != 'running' ORDER BY started_at, attempt_id LIMIT (SELECT MAX(COUNT(*) - ?1, 0) FROM inference_requests))", [MAX_RECORDS as i64])?;
    Ok(())
}

pub fn purge(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute("DELETE FROM inference_requests", [])?;
    Ok(())
}

fn read(
    conn: &Connection,
    query: &HistoryQuery,
    caller: Option<&str>,
    now: i64,
) -> rusqlite::Result<Vec<RequestRecord>> {
    prune(conn, now)?;
    let mut stmt = conn.prepare("SELECT attempt_id,request_id,caller_device_id,node_id,model_id,profile_id,started_at,finished_at,outcome,failure_code,admission_ms,first_frame_ms,elapsed_ms,prompt_tokens,completion_tokens,provenance_json FROM inference_requests WHERE (?1 IS NULL OR caller_device_id=?1) AND (?2 IS NULL OR model_id=?2) AND (?3 IS NULL OR outcome=?3) AND started_at>=?4 AND started_at<=?5 AND (?7 IS NULL OR attempt_id=?7) ORDER BY started_at DESC,attempt_id DESC LIMIT ?6")?;
    stmt.query_map(
        params![
            caller,
            query.model_id,
            query.outcome,
            query.after.unwrap_or(now.saturating_sub(RETENTION_SECONDS)),
            query.before.unwrap_or(now),
            query.limit.unwrap_or(100) as i64,
            query.attempt_id.map(|v| v.to_string())
        ],
        |row| {
            let provenance: String = row.get(15)?;
            Ok(RequestRecord {
                attempt_id: row.get(0)?,
                request_id: row.get(1)?,
                caller_device_id: row.get(2)?,
                node_id: row.get(3)?,
                model_id: row.get(4)?,
                profile_id: row.get(5)?,
                started_at: row.get(6)?,
                finished_at: row.get(7)?,
                outcome: row.get(8)?,
                failure_code: row.get(9)?,
                admission_ms: row.get(10)?,
                first_frame_ms: row.get(11)?,
                elapsed_ms: row.get(12)?,
                prompt_tokens: row.get(13)?,
                completion_tokens: row.get(14)?,
                provenance: serde_json::from_str(&provenance).ok(),
            })
        },
    )?
    .collect()
}

pub async fn list(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Query(query): Query<HistoryQuery>,
) -> Result<Json<Value>, Error> {
    state
        .require(&principal, Capability::InferenceRun)
        .resource("inference/requests")
        .check()?;
    query.validate()?;
    if query.all_callers && !principal.is_admin() {
        return Err(error(
            StatusCode::FORBIDDEN,
            "ROLE_FORBIDDEN",
            "Only an owner can read other callers' request history.",
        ));
    }
    let live_consent = state.telemetry_consent.clone();
    let db = state
        .database
        .clone()
        .ok_or_else(|| storage_error("unavailable"))?;
    let now = state.clock.now().unix_timestamp();
    let caller = (!query.all_callers).then(|| principal.device_id.to_string());
    let (recording, records) = tokio::task::spawn_blocking(move || {
        let conn = db.lock();
        let consent = live_consent.read();
        let recording = consent.functional;
        if !recording {
            purge(&conn)?;
        }
        read(&conn, &query, caller.as_deref(), now).map(|records| (recording, records))
    })
    .await
    .map_err(storage_error)?
    .map_err(storage_error)?;
    Ok(Json(
        json!({"recording":recording,"retention_seconds":RETENTION_SECONDS,"maximum_records":MAX_RECORDS,"records":records,"timing_source":"runtime_proxy","server_queue_ms":null}),
    ))
}

/// Clear only the caller's terminal records, with replay preserving records that finished after the accepted clear.
pub async fn clear(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
) -> Result<(StatusCode, Json<Value>), Error> {
    state
        .require(&principal, Capability::InferenceRun)
        .resource("inference/requests/clear")
        .check()?;
    let db = state
        .database
        .as_ref()
        .ok_or_else(|| storage_error("unavailable"))?;
    let caller = principal.device_id.to_string();
    let outcome = state
        .idempotency
        .execute(&mut db.lock(), &idempotency, |tx| {
            let deleted = tx.execute(
                "DELETE FROM inference_requests WHERE caller_device_id=?1 AND outcome!='running'",
                [&caller],
            )?;
            Ok(StoredResponse {
                status: StatusCode::OK,
                body: json!({"cleared":deleted,"active_requests_preserved":true}),
                operation_id: None,
            })
        })
        .map_err(|e| e.envelope())?;
    Ok(crate::idempotency::json_response(&outcome))
}

/// Let the original caller stop its live proxy stream; report missing handles after restart without replaying old requests.
pub async fn cancel(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Path(id): Path<Uuid>,
    idempotency: IdempotencyRequest,
) -> Result<Json<Value>, Error> {
    state
        .require(&principal, Capability::InferenceRun)
        .resource("inference/requests/cancel")
        .check()?;
    let db = state
        .database
        .as_ref()
        .ok_or_else(|| storage_error("unavailable"))?;
    let _admission = state.idempotency.admission_guard();
    let existing = state
        .idempotency
        .lookup(&mut db.lock(), &idempotency)
        .map_err(|e| e.envelope())?;
    if let Some(receipt) = existing {
        // Replay accepted cancellation intent only to the same live handle; never dispatch work or create a replacement handle.
        if receipt.response.body["cancel_requested"] == true
            && let Some(sender) = state.request_history.active.lock().get(&id)
        {
            sender.send_replace(true);
        }
        return Ok(Json(receipt.response.body));
    }
    let row: Option<String> = db
        .lock()
        .query_row(
            "SELECT outcome FROM inference_requests WHERE attempt_id=?1 AND caller_device_id=?2",
            params![id.to_string(), principal.device_id.to_string()],
            |r| r.get(0),
        )
        .optional()
        .map_err(storage_error)?;
    let Some(outcome) = row else {
        return Err(error(
            StatusCode::NOT_FOUND,
            "REQUEST_NOT_FOUND",
            "Request not found.",
        ));
    };
    let requested = outcome == "running";
    if requested && !state.request_history.active.lock().contains_key(&id) {
        return Err(error(
            StatusCode::CONFLICT,
            "REQUEST_OUTCOME_UNKNOWN",
            "This runtime cannot confirm or cancel the earlier attempt.",
        ));
    }
    let receipt = state
        .idempotency
        .execute(&mut db.lock(), &idempotency, |_| {
            Ok(StoredResponse {
                status: StatusCode::OK,
                body: json!({"cancel_requested":requested,"outcome":outcome}),
                operation_id: None,
            })
        })
        .map_err(|e| e.envelope())?;
    if requested && let Some(sender) = state.request_history.active.lock().get(&id) {
        sender.send_replace(true);
    }
    Ok(Json(receipt.response.body))
}

/// Cancel recorded attempts on revocation; unrecorded streams retain their own slot and budget limits.
pub(crate) fn cancel_running_attempts_for(state: &AppState, device_id: &Uuid) -> usize {
    let Some(db) = &state.database else {
        return 0;
    };
    let running: Vec<Uuid> = {
        let conn = db.lock();
        let Ok(mut statement) = conn.prepare(
            "SELECT attempt_id FROM inference_requests WHERE caller_device_id=?1 AND outcome='running'",
        ) else {
            return 0;
        };
        let Ok(rows) = statement.query_map(params![device_id.to_string()], |row| {
            row.get::<_, String>(0)
        }) else {
            return 0;
        };
        rows.flatten()
            .filter_map(|id| Uuid::parse_str(&id).ok())
            .collect()
    };
    let active = state.request_history.active.lock();
    running
        .iter()
        .filter_map(|id| active.get(id))
        .map(|sender| {
            sender.send_replace(true);
        })
        .count()
}

/// Record refusals only with valid catalogue identity, excluding invalid bodies and unknown model text without claiming engine execution.
pub(crate) fn record_refused(
    state: &AppState,
    principal: &Principal,
    requested: &str,
    code: &'static str,
    admission_ms: f64,
) {
    if !state.telemetry_consent.read().functional {
        return;
    }
    let Some(db) = &state.database else {
        return;
    };
    let catalogue_model = state.models.as_ref().and_then(|inventory| {
        inventory
            .snapshot()
            .recipe(requested)
            .map(|recipe| recipe.id().to_owned())
    });
    let model_id = catalogue_model.or_else(|| {
        state
            .engine
            .manager
            .as_ref()
            .and_then(|manager| manager.view())
            .filter(|view| view.served_name == requested)
            .map(|view| view.model_id)
    });
    let Some(model_id) = model_id else {
        return;
    };
    let conn = db.lock();
    let now = state.clock.now().unix_timestamp();
    let consent = state.telemetry_consent.read();
    if !consent.functional {
        return;
    }
    if prune(&conn, now).is_err() {
        return;
    }
    let active = conn
        .query_row(
            "SELECT COUNT(*) FROM inference_requests WHERE outcome='running'",
            [],
            |r| r.get::<_, i64>(0),
        )
        .unwrap_or(MAX_RECORDS as i64);
    if active >= MAX_RECORDS as i64 {
        return;
    }
    let written = conn.execute("INSERT INTO inference_requests(attempt_id,request_id,caller_device_id,node_id,model_id,started_at,finished_at,outcome,failure_code,admission_ms,elapsed_ms,provenance_json) VALUES (?1,?2,?3,?4,?5,?6,?6,'failed',?7,?8,?8,'null')",params![Uuid::new_v4().to_string(),Uuid::new_v4().to_string(),principal.device_id.to_string(),state.identity.node_id().to_string(),model_id,now,code,admission_ms]);
    if written.is_ok() {
        let _ = prune(&conn, now);
    }
}

pub(crate) struct Attempt {
    state: AppState,
    id: Uuid,
    started: Instant,
    first_frame_ms: Option<f64>,
    finished: bool,
    cancel_wait: CancelWait,
}

impl Attempt {
    /// Begin history only for a validated admitted fixed target, excluding raw model input and distributed execution.
    pub fn begin(
        state: &AppState,
        principal: &Principal,
        model_id: &str,
        admission_ms: f64,
    ) -> Option<Self> {
        let db = state.database.as_ref()?;
        if !state.telemetry_consent.read().functional {
            let _ = purge(&db.lock());
            return None;
        }
        let view = state
            .engine
            .manager
            .as_ref()?
            .view()
            .filter(|v| v.model_id == model_id)?;
        let profile = view
            .recipe
            .profiles
            .iter()
            .find(|p| p.id == view.profile_id);
        let provenance = DeploymentEvidence {
            recipe_digest: crate::crypto::sha256_hex(&serde_json::to_vec(&view.recipe).ok()?),
            recipe_revision: view.recipe.metadata.revision.clone(),
            source_revision: view.recipe.source.revision.clone(),
            engine_recipe: view.recipe.engine.recipe.clone(),
            engine_image: view.recipe.engine.image.clone(),
            context_length: profile.map(|p| p.max_model_length),
            max_sequences: profile.map(|p| p.max_sequences),
            runtime_version: state.config.runtime_version.clone(),
            verification: "admitted_recipe_only".into(),
        };
        let encoded = serde_json::to_string(&provenance).ok()?;
        if encoded.len() > 8192 {
            return None;
        }
        let now = state.clock.now().unix_timestamp();
        let id = Uuid::new_v4();
        // Generate history ids server-side; caller correlation headers cannot supply content-free metadata.
        let request_id = Uuid::new_v4();
        let conn = db.lock();
        let consent = state.telemetry_consent.read();
        if !consent.functional {
            return None;
        }
        prune(&conn, now).ok()?;
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM inference_requests", [], |r| r.get(0))
            .ok()?;
        if count >= MAX_RECORDS as i64 {
            // Keep accepted active attempts; a full history must not prevent inference.
            conn.execute("DELETE FROM inference_requests WHERE attempt_id IN (SELECT attempt_id FROM inference_requests WHERE outcome!='running' ORDER BY started_at,attempt_id LIMIT 1)",[]).ok()?;
            if conn
                .query_row("SELECT COUNT(*) FROM inference_requests", [], |r| {
                    r.get::<_, i64>(0)
                })
                .ok()?
                >= MAX_RECORDS as i64
            {
                return None;
            }
        }
        conn.execute("INSERT INTO inference_requests (attempt_id,request_id,caller_device_id,node_id,model_id,profile_id,started_at,outcome,admission_ms,provenance_json) VALUES (?1,?2,?3,?4,?5,?6,?7,'running',?8,?9)",params![id.to_string(),request_id.to_string(),principal.device_id.to_string(),state.identity.node_id().to_string(),model_id,view.profile_id,now,admission_ms,encoded]).ok()?;
        drop(conn);
        let (sender, mut receiver) = watch::channel(false);
        state.request_history.active.lock().insert(id, sender);
        let cancel_wait = Box::pin(async move {
            loop {
                if *receiver.borrow_and_update() {
                    break;
                }
                if receiver.changed().await.is_err() {
                    std::future::pending::<()>().await;
                }
            }
        });
        Some(Self {
            state: state.clone(),
            id,
            started: Instant::now(),
            first_frame_ms: None,
            finished: false,
            cancel_wait,
        })
    }

    pub fn id(&self) -> Uuid {
        self.id
    }
    pub async fn cancelled(&mut self) {
        self.cancel_wait.as_mut().await
    }
    pub fn poll_cancel(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.cancel_wait.as_mut().poll(cx)
    }
    pub fn first_frame(&mut self) {
        if self.first_frame_ms.is_none() {
            self.first_frame_ms = Some(self.started.elapsed().as_secs_f64() * 1000.0);
            if let Some(db) = &self.state.database {
                let conn = db.lock();
                let consent = self.state.telemetry_consent.read();
                if consent.functional {
                    let _ = conn.execute("UPDATE inference_requests SET first_frame_ms=?1 WHERE attempt_id=?2 AND outcome='running'",params![self.first_frame_ms,self.id.to_string()]);
                }
            }
        }
    }
    pub fn finish(&mut self, outcome: &str, code: Option<&str>, usage: Option<(u64, u64)>) {
        if self.finished {
            return;
        }
        self.finished = true;
        self.state.request_history.active.lock().remove(&self.id);
        if let Some(db) = &self.state.database {
            let now = self.state.clock.now().unix_timestamp();
            let conn = db.lock();
            let consent = self.state.telemetry_consent.read();
            if !consent.functional {
                let _ = purge(&conn);
                return;
            }
            let (prompt, completion) = usage.map_or((None, None), |(p, c)| {
                (i64::try_from(p).ok(), i64::try_from(c).ok())
            });
            let result=conn.execute("UPDATE inference_requests SET outcome=?1,failure_code=?2,finished_at=?3,first_frame_ms=?4,elapsed_ms=?5,prompt_tokens=?6,completion_tokens=?7 WHERE attempt_id=?8 AND outcome='running'",params![outcome,code,now,self.first_frame_ms,self.started.elapsed().as_secs_f64()*1000.0,prompt,completion,self.id.to_string()]);
            if result.is_err() {
                tracing::warn!("request history completion could not be persisted");
            }
        }
    }
}

impl Drop for Attempt {
    fn drop(&mut self) {
        self.finish("cancelled_unconfirmed", Some("PROXY_DISCONNECTED"), None);
    }
}

#[cfg(test)]
#[path = "request_history/tests.rs"]
mod tests;
