//! Expose durable downloads, operations, event streams and provider-credential management.

use std::path::PathBuf;

use std::sync::Arc;

use axum::Json;

use axum::extract::{Extension, Path as RoutePath, Query, State};

use axum::http::{HeaderMap, StatusCode};

use axum::response::{IntoResponse, Response, Sse};

use serde_json::{Value, json};

use spark_privd::protocol::{PrivilegedOperation, PrivilegedResponse, SecretString};

use crate::auth::{AuthenticatedRequest, Principal};

use crate::credentials::CredentialStore;

use crate::download::{DownloadContext, IsCancelled, ProgressSink};

use crate::events::EventBus;

use crate::idempotency::{IdempotencyRequest, StoredResponse, json_response};

use crate::models::internal_envelope;

use crate::preview::{
    PreviewBinding, PreviewConsequences, PreviewDraft, PreviewEvidence, PreviewMessage,
    PreviewRecipeIdentity, action_key, active_engine, target_and_cluster,
};

use crate::state::AppState;

/// Start a durable model download and return its operation with HTTP 202.
pub async fn install_model(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    RoutePath(id): RoutePath<String>,
    Json(request): Json<InstallModelBody>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, crate::capability::Capability::ModelInstall)
        .resource(format!(
            "model/{}/install",
            crate::models::decode_path_param(&id)
        ))
        .check()?;
    let Some(db) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    let replay = {
        let mut connection = db.lock();
        state
            .idempotency
            .lookup(&mut connection, &idempotency)
            .map_err(|error| error.envelope())?
    };
    if let Some(outcome) = replay {
        return if outcome.response.status.is_success() {
            Ok(json_response(&outcome))
        } else {
            Err(json_response(&outcome))
        };
    }
    let draft_result = install_preview_draft(
        &state,
        &id,
        request.recipe_revision.as_deref(),
        request.provider_credential_id.as_deref(),
    )
    .await;
    let _admission = state.idempotency.admission_guard();
    let replay = state
        .idempotency
        .lookup(&mut db.lock(), &idempotency)
        .map_err(|error| error.envelope())?;
    if let Some(outcome) = replay {
        return if outcome.response.status.is_success() {
            Ok(json_response(&outcome))
        } else {
            Err(json_response(&outcome))
        };
    }
    let (draft, provider_credential_id) = match draft_result {
        Ok(draft) => draft,
        Err(failure) => {
            let resource = format!("model/{}", crate::models::decode_path_param(&id));
            let reason = crate::audit::response_code(&failure, "MODEL_APPLY_REFUSED");
            crate::audit::append_refusal(
                db,
                state.clock.as_ref(),
                principal.device_id,
                &principal.role,
                "/api/v1/models/{model_id}/install",
                "model.install",
                Some(&resource),
                idempotency.request_id,
                &reason,
            )
            .map_err(crate::audit::unavailable_envelope)?;
            return Err(failure);
        }
    };
    let acceptance_key = format!("{}:{}", idempotency.device_id, idempotency.key);
    if let Err(error) = state.previews.validate(
        request.accepted_preview_digest.as_deref(),
        &draft,
        &acceptance_key,
    ) {
        let resource = format!("model/{}", crate::models::decode_path_param(&id));
        crate::audit::append_refusal(
            db,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            "/api/v1/models/{model_id}/install",
            "model.install",
            Some(&resource),
            idempotency.request_id,
            error.code(),
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err(error.envelope());
    }
    let recipe = state
        .models
        .as_ref()
        .and_then(|inventory| {
            inventory
                .snapshot()
                .recipe(&crate::models::decode_path_param(&id))
                .cloned()
        })
        .ok_or_else(|| internal_envelope("model recipe unavailable after preview validation"))?;
    let outcome = {
        let mut conn = db.lock();
        let audit_resource = format!("model/{}", recipe.id());
        let audit_details = json!({ "recipe_revision": request.recipe_revision });
        state
            .idempotency
            .create_operation_audited(
                &mut conn,
                &idempotency,
                &state.jobs,
                "model.install",
                Some(recipe.id()),
                &json!({
                    "model": recipe.id(),
                    "recipe_revision": request.recipe_revision,
                    "provider_credential_id": request.provider_credential_id,
                })
                .to_string(),
                &principal.role,
                "/api/v1/models/{model_id}/install",
                Some(&audit_resource),
                &audit_details,
            )
            .map_err(|error| error.envelope())?
    };
    if !outcome.created {
        return if outcome.response.status.is_success() {
            Ok(json_response(&outcome))
        } else {
            Err(json_response(&outcome))
        };
    }
    let operation_id = outcome
        .response
        .operation_id
        .expect("operation submissions always carry an operation id");

    // Run the download on a blocking worker; cancellation is cooperative.
    if let Err(error) =
        spawn_install_worker(&state, operation_id, recipe.id(), provider_credential_id)
    {
        tracing::error!(%operation_id, %error, "model install worker could not start");
        let status = StatusCode::INTERNAL_SERVER_ERROR;
        let body = json!({
            "error": {
                "code": "MODEL_DOWNLOAD_FAILED",
                "message": "model install worker could not start",
                "request_id": crate::route::current_request_id(),
            }
        });
        let replacement = StoredResponse {
            status,
            body: body.clone(),
            operation_id: Some(operation_id),
        };
        let mut connection = db.lock();
        state
            .idempotency
            .replace_response(&mut connection, &idempotency, &replacement, |transaction| {
                state
                    .jobs
                    .fail(transaction, operation_id, "MODEL_DOWNLOAD_FAILED")
            })
            .map_err(|replace_error| replace_error.envelope())?;
        return Err((status, Json(body)));
    }

    Ok(json_response(&outcome))
}

#[cfg(test)]
#[path = "download_api/tests.rs"]
mod tests;

mod install_worker;
pub(crate) use install_worker::{ensure_engine_image_ready, spawn_install_worker};

mod install_preview;
pub use install_preview::{InstallModelBody, InstallModelPreviewBody, preview_install_model};
use install_preview::{install_preview_draft, validate_engine_image_readiness};

mod event_stream;
pub use event_stream::stream_events;

mod operations;
pub use operations::{OperationListQuery, cancel_operation, get_operation, list_operations};

mod credentials;
pub use credentials::{AddCredentialRequest, add_credential, list_credentials, revoke_credential};
