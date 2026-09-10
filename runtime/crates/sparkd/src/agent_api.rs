//! Expose durable agent changes and recorded approval, rejection and merge decisions.

use axum::Json;
use axum::extract::{Extension, State};
use axum::http::StatusCode;
use serde_json::{Value, json};

use crate::auth::Principal;
use crate::capability::Capability;
use crate::idempotency::{IdempotencyRequest, StoredResponse, json_response};
use crate::state::AppState;

fn internal_envelope(message: &str) -> (StatusCode, Json<Value>) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({
            "error": { "code": "INTERNAL_ERROR", "message": message }
        })),
    )
}

fn agent(state: &AppState) -> Result<&crate::agent::AgentService, ResponseErr> {
    state
        .agents
        .manager
        .as_ref()
        .ok_or(ResponseErr(
            StatusCode::INTERNAL_SERVER_ERROR,
            "agent service unavailable",
        ))
        .map(|a| a.as_ref())
}

struct ResponseErr(StatusCode, &'static str);

/// Start an agent change for a project.
pub async fn start_agent(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    axum::extract::Path(project_id): axum::extract::Path<uuid::Uuid>,
    Json(body): Json<Value>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::AgentRun)
        .in_project(project_id)
        .resource(format!("project/{project_id}/agents"))
        .check()?;
    if !state.agents.execution_available {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({
                "error": {
                    "code": "AGENT_EXECUTION_UNAVAILABLE",
                    "message": "This runtime does not have a model-backed coding agent configured."
                }
            })),
        ));
    }
    let task = body.get("task").and_then(Value::as_str).unwrap_or("");
    let base_commit = body
        .get("base_commit")
        .and_then(Value::as_str)
        .map(str::to_owned);
    if task.is_empty() || task.chars().count() > 20_000 {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(
                json!({ "error": { "code": "TASK_REQUIRED", "message": "task must be 1..=20000 characters" } }),
            ),
        ));
    }
    let service = match agent(&state) {
        Ok(service) => service,
        Err(e) => {
            return Err((
                e.0,
                Json(json!({ "error": { "code": "INTERNAL_ERROR", "message": e.1 } })),
            ));
        }
    };
    let Some(db) = &state.database else {
        return Err(internal_envelope("no database"));
    };

    let _admission = state.idempotency.admission_guard();
    let outcome = {
        let mut conn = db.lock();
        let row = crate::store::project_row(&conn, &project_id)
            .map_err(|_| internal_envelope("project lookup failed"))?;
        if row.is_some_and(|row| row.state == "deleting") {
            return Err(internal_envelope("PROJECT_DELETING"));
        }
        state
            .idempotency
            .create_operation(
                &mut conn,
                &idempotency,
                &state.jobs,
                "project.agent",
                None,
                &json!({ "project_id": project_id, "task": task, "base_commit": base_commit })
                    .to_string(),
            )
            .map_err(|error| error.envelope())?
    };
    if !outcome.created {
        return Ok(json_response(&outcome));
    }
    let operation_id = outcome.response.operation_id.unwrap();

    if let Err(error) =
        service.start_change(operation_id, &project_id, task, base_commit.as_deref())
    {
        let (status, Json(body)) = internal_envelope(&error);
        let replacement = StoredResponse {
            status,
            body: body.clone(),
            operation_id: Some(operation_id),
        };
        state
            .idempotency
            .replace_response(&mut db.lock(), &idempotency, &replacement, |transaction| {
                state.jobs.fail(transaction, operation_id, &error)
            })
            .map_err(|error| error.envelope())?;
        return Err((status, Json(body)));
    }

    Ok(json_response(&outcome))
}

/// List project changes with diff and test summaries.
pub async fn list_changes(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    axum::extract::Path(project_id): axum::extract::Path<uuid::Uuid>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::AgentChangeRead)
        .in_project(project_id)
        .resource(format!("project/{project_id}/changes"))
        .check()?;
    let service = agent(&state).map_err(|e| {
        (
            e.0,
            Json(json!({ "error": { "code": "INTERNAL_ERROR", "message": e.1 } })),
        )
    })?;
    let rows = service
        .list_changes(&project_id)
        .map_err(|e| internal_envelope(&e))?;
    let items: Vec<Value> = rows.iter().map(change_view).collect();
    Ok(Json(json!({ "items": items })))
}

fn change_view(row: &crate::store::ChangeRow) -> Value {
    let evidence =
        serde_json::from_str::<crate::change_evidence::ReviewEvidence>(&row.review_evidence_json)
            .ok();
    json!({
        "id": row.id,
        "project_id": row.project_id,
        "status": row.status,
        "task": row.task,
        "base_commit": row.base_commit,
        "head_commit": row.head_commit,
        "protected_head_commit": row.protected_head_commit,
        "review_digest": row.review_digest,
        "branch": row.worktree_branch,
        "changed_files": evidence.as_ref().map(|item| item.changed_files.clone()).unwrap_or_default(),
        "test_evidence": evidence.as_ref().map(|item| item.test_evidence.clone()).unwrap_or_default(),
        "tool_evidence": evidence.as_ref().map(|item| item.tool_evidence.clone()).unwrap_or_default(),
        "evidence_complete": evidence.as_ref().is_some_and(|item| item.evidence_complete),
        "created_at": row.created_at,
        "updated_at": row.updated_at,
    })
}

/// Approve a project change.
pub async fn approve_change(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    axum::extract::Path((project_id, change_id)): axum::extract::Path<(uuid::Uuid, uuid::Uuid)>,
    Json(body): Json<Value>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    act_on_change(
        &state,
        &principal,
        &idempotency,
        &project_id,
        &change_id,
        body,
        ReviewDecision::Approve,
    )
    .await
}

/// What a reviewer decided, and what the runtime does about it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ReviewDecision {
    Approve,
    /// ADR-014: corrections keep the worktree and its evidence and return the change to the agent.
    RequestChanges,
    /// The change is closed; its worktree and audit stay for the record.
    Reject,
}

impl ReviewDecision {
    fn name(self) -> &'static str {
        match self {
            Self::Approve => "approve",
            Self::RequestChanges => "request_changes",
            Self::Reject => "reject",
        }
    }
}

/// Reject a project change.
pub async fn reject_change(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    axum::extract::Path((project_id, change_id)): axum::extract::Path<(uuid::Uuid, uuid::Uuid)>,
    Json(body): Json<Value>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    act_on_change(
        &state,
        &principal,
        &idempotency,
        &project_id,
        &change_id,
        body,
        ReviewDecision::Reject,
    )
    .await
}

/// Request corrections to a reviewed change.
pub async fn request_changes(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    axum::extract::Path((project_id, change_id)): axum::extract::Path<(uuid::Uuid, uuid::Uuid)>,
    Json(body): Json<Value>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    act_on_change(
        &state,
        &principal,
        &idempotency,
        &project_id,
        &change_id,
        body,
        ReviewDecision::RequestChanges,
    )
    .await
}

async fn act_on_change(
    state: &AppState,
    principal: &Principal,
    idempotency: &IdempotencyRequest,
    project_id: &uuid::Uuid,
    change_id: &uuid::Uuid,
    body: Value,
    decision: ReviewDecision,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let approve = decision == ReviewDecision::Approve;
    let service = agent(state).map_err(|e| {
        (
            e.0,
            Json(json!({ "error": { "code": "INTERNAL_ERROR", "message": e.1 } })),
        )
    })?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("no database"))?;
    let _admission = state.idempotency.admission_guard();
    if let Some(outcome) = state
        .idempotency
        .lookup(&mut database.lock(), idempotency)
        .map_err(|error| error.envelope())?
    {
        return if outcome.response.status.is_success() {
            Ok(json_response(&outcome))
        } else {
            Err(json_response(&outcome))
        };
    }
    let change = service
        .change_in_project(project_id, change_id)
        .map_err(|_| {
            (
                StatusCode::NOT_FOUND,
                Json(json!({
                    "error": { "code": "CHANGE_NOT_FOUND", "message": "CHANGE_NOT_FOUND" }
                })),
            )
        })?;
    state
        .require(principal, Capability::AgentChangeApprove)
        .in_project(change.project_id)
        .resource(format!("project/{}/changes/{change_id}", change.project_id))
        .details(json!({ "decision": decision.name() }))
        .check()?;
    let comment = body
        .get("comment")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let review_digest = body
        .get("review_digest")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            (
                StatusCode::UNPROCESSABLE_ENTITY,
                Json(json!({
                    "error": {
                        "code": "REVIEW_DIGEST_REQUIRED",
                        "message": "review_digest must identify the evidence shown to the reviewer"
                    }
                })),
            )
        })?;
    if review_digest.len() != 64
        || !review_digest
            .chars()
            .all(|character| character.is_ascii_hexdigit())
    {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({
                "error": { "code": "REVIEW_DIGEST_INVALID", "message": "review_digest must be 64 hexadecimal characters" }
            })),
        ));
    }
    if !approve
        && comment
            .as_deref()
            .is_none_or(|value| value.trim().is_empty())
    {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({
                "error": { "code": "CHANGE_COMMENT_REQUIRED", "message": "requesting changes requires a comment" }
            })),
        ));
    }

    let result = match decision {
        ReviewDecision::Approve => service.approve_change(
            project_id,
            change_id,
            &principal.device_id,
            review_digest,
            comment.as_deref(),
        ),
        ReviewDecision::RequestChanges => service.request_change_updates(
            project_id,
            change_id,
            &principal.device_id,
            review_digest,
            comment.as_deref(),
        ),
        ReviewDecision::Reject => service.reject_change(
            project_id,
            change_id,
            &principal.device_id,
            review_digest,
            comment.as_deref(),
        ),
    };

    // Create a merge operation only when the change references a durable operation.
    let response = match result {
        Ok(()) => match service.get_change(change_id) {
            Ok(row) => StoredResponse {
                status: StatusCode::OK,
                body: json!({ "change": change_view(&row) }),
                operation_id: Some(row.operation_id),
            },
            Err(error) => {
                let (status, Json(body)) = internal_envelope(&error);
                StoredResponse {
                    status,
                    body,
                    operation_id: None,
                }
            }
        },
        Err(e) if e.starts_with("CHANGE_NOT_FOUND") => StoredResponse {
            status: StatusCode::NOT_FOUND,
            body: json!({ "error": { "code": "CHANGE_NOT_FOUND", "message": "CHANGE_NOT_FOUND" } }),
            operation_id: None,
        },
        Err(e) if e.starts_with("CHANGE_NOT_IN_REVIEW") => StoredResponse {
            status: StatusCode::CONFLICT,
            body: json!({ "error": { "code": "CHANGE_NOT_IN_REVIEW", "message": e } }),
            operation_id: None,
        },
        Err(e) if e.starts_with("REVIEW_") || e.starts_with("PROTECTED_HEAD_DRIFT") => {
            StoredResponse {
                status: StatusCode::CONFLICT,
                body: json!({ "error": { "code": e.split(':').next().unwrap_or("REVIEW_EVIDENCE_STALE"), "message": e } }),
                operation_id: None,
            }
        }
        Err(e) => {
            let (status, Json(body)) = internal_envelope(&e);
            StoredResponse {
                status,
                body,
                operation_id: None,
            }
        }
    };
    let outcome = state
        .idempotency
        .execute(&mut database.lock(), idempotency, |_| Ok(response))
        .map_err(|error| error.envelope())?;
    if outcome.response.status.is_success() {
        Ok(json_response(&outcome))
    } else {
        Err(json_response(&outcome))
    }
}
