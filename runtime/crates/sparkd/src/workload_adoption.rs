//! Adopt only exact verified vLLM image, snapshot and security configuration; privd inspects without exposing environment or secrets.

use std::time::Duration;

use axum::Extension;

use axum::extract::{Path, State};

use axum::http::{HeaderMap, StatusCode};

use axum::response::Json;

use futures::StreamExt;

use serde::Deserialize;

use serde_json::{Value, json};

use spark_privd::PrivilegedOperation;

use spark_privd::adoption::{AdoptionInspection, ModelAdoptionPolicy};

use crate::auth::{AuthenticatedRequest, Principal};

use crate::idempotency::{IdempotencyRequest, StoredResponse, json_response};

use crate::preview::{
    PreviewBinding, PreviewConsequences, PreviewDraft, PreviewEvidence, PreviewMessage,
    PreviewRecipeIdentity, action_key, active_engine, target_and_cluster,
};

use crate::state::AppState;

const ADOPT_ROUTE: &str = "/api/v1/workloads/{workload_id}/adopt";

const RELINQUISH_ROUTE: &str = "/api/v1/workloads/{workload_id}/relinquish";

const INSPECTION_TIMEOUT: Duration = Duration::from_secs(3);

const MAX_MODEL_LIST_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AdoptionRequest {
    pub model_id: String,
    pub profile_id: String,
    pub accepted_preview_digest: String,
}

fn error(status: StatusCode, code: &str, message: &str) -> (StatusCode, Json<Value>) {
    (
        status,
        Json(json!({
            "error": {
                "code": code,
                "message": message,
                "request_id": crate::route::current_request_id(),
            }
        })),
    )
}

fn require_administrator(principal: &Principal) -> Result<(), (StatusCode, Json<Value>)> {
    if principal.is_admin() {
        Ok(())
    } else {
        Err(error(
            StatusCode::FORBIDDEN,
            "ROLE_FORBIDDEN",
            "Only a Spark administrator or owner can adopt an external workload.",
        ))
    }
}

fn presence_key(
    state: &AppState,
    principal: &Principal,
) -> Result<Option<Vec<u8>>, (StatusCode, Json<Value>)> {
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| error(StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL", "no database"))?;
    crate::store::load_presence_key_by_device_id(&database.lock(), &principal.device_id).map_err(
        |_| {
            error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "INTERNAL",
                "presence unavailable",
            )
        },
    )
}

fn verify_presence(
    state: &AppState,
    principal: &Principal,
    headers: &HeaderMap,
    authenticated_request: &AuthenticatedRequest,
) -> Result<(), (StatusCode, Json<Value>)> {
    let key = presence_key(state, principal)?;
    crate::user_presence::verify(
        headers.get(crate::user_presence::HEADER_USER_PRESENCE),
        key.as_deref(),
        authenticated_request,
        state.clock.now(),
    )
    .map_err(|failure| {
        error(
            StatusCode::FORBIDDEN,
            failure.code(),
            "Fresh user presence is required to change workload ownership.",
        )
    })
}

pub async fn adopt(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    Path(workload_id): Path<String>,
    headers: HeaderMap,
    idempotency: IdempotencyRequest,
    Json(request): Json<AdoptionRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    require_administrator(&principal)?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| error(StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL", "no database"))?;
    let manager = state.engine.manager.as_ref().ok_or_else(|| {
        error(
            StatusCode::SERVICE_UNAVAILABLE,
            "ENGINE_UNAVAILABLE",
            "The model lifecycle controller is unavailable.",
        )
    })?;
    // Replay completed adoption despite later container loss, then recheck under admission without holding a non-Send guard across inspection.
    if let Some(outcome) = state
        .idempotency
        .lookup(&mut database.lock(), &idempotency)
        .map_err(|failure| failure.envelope())?
    {
        return Ok(json_response(&outcome));
    }
    let (draft, recipe, host_port) =
        adoption_draft(&state, &workload_id, &request.model_id, &request.profile_id).await?;
    let _admission = state.idempotency.admission_guard();
    if let Some(outcome) = state
        .idempotency
        .lookup(&mut database.lock(), &idempotency)
        .map_err(|failure| failure.envelope())?
    {
        return Ok(json_response(&outcome));
    }
    state
        .previews
        .validate(
            Some(&request.accepted_preview_digest),
            &draft,
            &format!("{}:{}", idempotency.device_id, idempotency.key),
        )
        .map_err(|failure| failure.envelope())?;
    verify_presence(&state, &principal, &headers, &authenticated_request)?;
    let host_port = host_port.ok_or_else(|| {
        error(
            StatusCode::CONFLICT,
            "WORKLOAD_ADOPTION_BLOCKED",
            "The external workload is not eligible for adoption.",
        )
    })?;
    let outcome = state
        .idempotency
        .create_operation_audited(
            &mut database.lock(),
            &idempotency,
            &state.jobs,
            "workload.adopt",
            Some(&workload_id),
            &json!({
                "workload_id": workload_id,
                "model_id": request.model_id,
                "profile_id": request.profile_id,
            })
            .to_string(),
            &principal.role,
            ADOPT_ROUTE,
            Some(&workload_id),
            &json!({
                "model_id": request.model_id,
                "profile_id": request.profile_id,
            }),
        )
        .map_err(|failure| failure.envelope())?;
    if !outcome.created {
        return Ok(json_response(&outcome));
    }
    let operation_id = outcome
        .response
        .operation_id
        .expect("adoption operation id");
    if let Err(failure) = manager.spawn_adopt(
        operation_id,
        &recipe,
        &request.profile_id,
        workload_id.clone(),
        host_port,
    ) {
        let (status, Json(body)) = failure.envelope();
        let replacement = StoredResponse {
            status,
            body: body.clone(),
            operation_id: Some(operation_id),
        };
        state
            .idempotency
            .replace_response(
                &mut database.lock(),
                &idempotency,
                &replacement,
                |transaction| state.jobs.fail(transaction, operation_id, failure.code()),
            )
            .map_err(|error| error.envelope())?;
        return Err((status, Json(body)));
    }
    Ok(json_response(&outcome))
}

#[cfg(test)]
#[path = "workload_adoption/tests.rs"]
mod tests;

mod adoption_preview;
use adoption_preview::adoption_draft;
pub use adoption_preview::{AdoptionPreviewRequest, preview_adoption};

mod relinquish;
pub use relinquish::{RelinquishRequest, preview_relinquish, relinquish};
