//! Verify authenticated catalogue candidates against configured trust before atomic same-directory promotion.

use std::collections::{HashMap, HashSet};

use std::fs::{self, File, OpenOptions};

use std::io::{Read as _, Write as _};

use std::os::unix::fs::OpenOptionsExt as _;

use std::path::{Path, PathBuf};

use std::sync::Arc;

use axum::Json;

use axum::extract::{Extension, State};

use axum::http::{HeaderMap, StatusCode};

use serde::Deserialize;

use serde_json::{Value, json};

use sha2::{Digest as _, Sha256};

use spark_models::catalogue::SignedCatalogue;

use spark_models::verify::CatalogueRoot;

use crate::auth::{AuthenticatedRequest, Principal};

use crate::capability::Capability;

use crate::idempotency::{IdempotencyRequest, StoredResponse, json_response};

use crate::jobs::OperationLease;

use crate::models::{LiveModelInventory, ModelInventory, internal_envelope};

use crate::preview::{
    PreviewBinding, PreviewConsequences, PreviewDraft, PreviewEvidence, PreviewMessage,
    target_and_cluster,
};

use crate::state::AppState;

pub const MAX_CATALOGUE_BYTES: usize = 2 * 1024 * 1024;

const REFRESH_ROUTE: &str = "/api/v1/catalogue/refresh";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CatalogueRefreshPreviewRequest {
    pub candidate_json: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CatalogueRefreshRequest {
    pub candidate_json: String,
    pub accepted_preview_digest: String,
}

fn require_owner(principal: &Principal) -> Result<(), (StatusCode, Json<Value>)> {
    if principal.role == "owner" {
        Ok(())
    } else {
        Err((
            StatusCode::FORBIDDEN,
            Json(
                json!({ "error": { "code": "ROLE_FORBIDDEN", "message": "owner access is required" } }),
            ),
        ))
    }
}

fn refresh_service(
    state: &AppState,
) -> Result<Arc<CatalogueRefreshService>, (StatusCode, Json<Value>)> {
    state
        .catalogue_refresh
        .clone()
        .ok_or_else(|| CatalogueRefreshError::Unavailable.envelope())
}

fn preview_draft(
    state: &AppState,
    service: &CatalogueRefreshService,
    candidate_json: &str,
) -> Result<PreviewDraft, (StatusCode, Json<Value>)> {
    let candidate = service
        .verify_candidate(candidate_json)
        .map_err(|error| error.envelope())?;
    let installed_check = service.check_installed_models(&candidate, &service.database.lock());
    let (target, cluster_available, cluster) =
        target_and_cluster(state).map_err(|error| internal_envelope(&error))?;
    let active = state
        .engine
        .manager
        .as_ref()
        .and_then(|manager| manager.view());
    let mut blockers = Vec::new();
    if let Err(error) = installed_check {
        let recovery = match &error {
            CatalogueRefreshError::RecoveryRequired => {
                "Reapply the current signed catalogue to finish its interrupted refresh, then preview the newer catalogue."
            }
            CatalogueRefreshError::InstallInProgress | CatalogueRefreshError::ModelInUse(_) => {
                "Wait for model operations and cluster launches to finish, then preview this catalogue again."
            }
            _ => {
                "Use a signed catalogue that retains the installed source, engine, security policy, and system reserve; preset corrections need a new recipe revision and must not overwrite custom settings."
            }
        };
        blockers.push(PreviewMessage::blocker(
            error.code(),
            &error.to_string(),
            recovery,
        ));
    }
    let mut warnings = Vec::new();
    let current = service.models.snapshot();
    for recipe in &candidate.inventory.recipes {
        if let Some(old) = current.recipe(recipe.id()) {
            if old.memory != recipe.memory {
                warnings.push(PreviewMessage::warning(
                    "SIGNED_MEMORY_ESTIMATE_CORRECTION",
                    "Memory estimates change on the next launch; the protected system reserve and saved safety history are kept.",
                ));
            }
            if old
                .profiles
                .iter()
                .any(|previous| !recipe.profiles.iter().any(|next| next.id == previous.id))
            {
                warnings.push(PreviewMessage::warning(
                    "SIGNED_PRESET_RETIREMENT",
                    "Some older presets are replaced; their history is kept, and a saved preset that is no longer offered must be chosen again before launch.",
                ));
            }
            for next in &recipe.profiles {
                if let Some(previous) = old.profiles.iter().find(|profile| profile.id == next.id)
                    && previous != next
                {
                    warnings.push(PreviewMessage::warning(
                        &format!("SIGNED_PRESET_CORRECTION_{}_{}", recipe.id(), next.id),
                        &format!(
                            "{} / {}: context {} to {}, simultaneous requests {} to {}, GPU allocation {:.0}% to {:.0}%, estimated memory {} to {} bytes; saved safety history is kept and the change applies on the next launch.",
                            recipe.metadata.display_name, next.display_name,
                            previous.max_model_length, next.max_model_length,
                            previous.max_sequences, next.max_sequences,
                            previous.gpu_memory_utilisation * 100.0, next.gpu_memory_utilisation * 100.0,
                            previous.expected_peak_bytes, next.expected_peak_bytes,
                        ),
                    ));
                }
            }
        }
    }
    if active.is_some() {
        warnings.push(PreviewMessage::warning(
            "ACTIVE_ENGINE_UNCHANGED",
            "The running model keeps its current verified recipe until it is unloaded.",
        ));
    }
    let current_digest = service
        .current_digest()
        .map_err(|error| error.envelope())?
        .unwrap_or_else(|| "none".into());
    Ok(PreviewDraft {
        action: "catalogue.refresh",
        action_key: format!("catalogue.refresh:{}:{current_digest}", candidate.digest),
        binding: PreviewBinding {
            target,
            recipe: None,
            evidence: PreviewEvidence {
                external_workload_id: None,
                external_workload_evidence_digest: None,
                external_workload_healthy: None,
                remote: None,
                install_state: None,
                installed_bytes: None,
                removable_bytes: None,
                download_bytes: Some(candidate.raw.len() as u64),
                locally_reusable_bytes: None,
                required_disk_bytes: Some(candidate.raw.len() as u64),
                disk_free_bytes: Some(state.telemetry.system().disk_free_bytes),
                expected_disk_free_after_bytes: Some(
                    state
                        .telemetry
                        .system()
                        .disk_free_bytes
                        .saturating_sub(candidate.raw.len() as u64),
                ),
                required_memory_bytes: None,
                available_memory_bytes: None,
                system_reserve_bytes: None,
                expected_memory_headroom_bytes: None,
                launch_memory: None,
                memory_pressure: None,
                memory_admission: None,
                profile_failure_code: None,
                active_inference_available: state.engine.manager.is_some(),
                engine_transitioning: state
                    .engine
                    .manager
                    .as_ref()
                    .is_some_and(|manager| manager.is_transitioning()),
                active_engine: None,
                cluster_membership_available: cluster_available,
                cluster_membership_source: cluster_available.then(|| "runtime".to_owned()),
                cluster,
            },
        },
        consequences: PreviewConsequences::default(),
        blockers,
        warnings,
    })
}

pub async fn catalogue_status(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::NodeRead)
        .resource("catalogue")
        .check()?;
    let service = refresh_service(&state)?;
    service.status().map(Json).map_err(|error| error.envelope())
}

pub async fn preview_catalogue_refresh(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Json(request): Json<CatalogueRefreshPreviewRequest>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    require_owner(&principal)?;
    let service = refresh_service(&state)?;
    let draft = preview_draft(&state, &service, &request.candidate_json)?;
    let preview = state
        .previews
        .issue(&draft)
        .map_err(|error| internal_envelope(&error.to_string()))?;
    Ok(Json(preview))
}

pub async fn refresh_catalogue(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    headers: HeaderMap,
    idempotency: IdempotencyRequest,
    Json(request): Json<CatalogueRefreshRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    require_owner(&principal)?;
    let service = refresh_service(&state)?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("database unavailable"))?;
    let _admission = state.idempotency.admission_guard();
    if let Some(outcome) = state
        .idempotency
        .lookup(&mut database.lock(), &idempotency)
        .map_err(|error| error.envelope())?
    {
        return Ok(json_response(&outcome));
    }
    let presence_key =
        crate::store::load_presence_key_by_device_id(&database.lock(), &principal.device_id)
            .map_err(|error| internal_envelope(&error.to_string()))?;
    if let Err(error) = crate::user_presence::verify(
        headers.get(crate::user_presence::HEADER_USER_PRESENCE),
        presence_key.as_deref(),
        &authenticated_request,
        state.clock.now(),
    ) {
        crate::audit::append_refusal(
            database,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            REFRESH_ROUTE,
            "catalogue.refresh",
            Some("catalogue"),
            idempotency.request_id,
            error.code(),
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err((
            StatusCode::FORBIDDEN,
            Json(json!({
                "error": {
                    "code": error.code(),
                    "message": "fresh user presence is required to refresh model recipes",
                    "request_id": idempotency.request_id,
                }
            })),
        ));
    }
    let draft = preview_draft(&state, &service, &request.candidate_json)?;
    let acceptance_key = format!("{}:{}", idempotency.device_id, idempotency.key);
    state
        .previews
        .validate(
            Some(&request.accepted_preview_digest),
            &draft,
            &acceptance_key,
        )
        .map_err(|error| error.envelope())?;
    let outcome = state
        .idempotency
        .create_noncancellable_operation_audited(
            &mut database.lock(),
            &idempotency,
            &state.jobs,
            "catalogue.refresh",
            Some("catalogue"),
            &json!({ "candidate_json": request.candidate_json }).to_string(),
            &principal.role,
            REFRESH_ROUTE,
            Some("catalogue"),
            &json!({ "source": "device_local_signed_snapshot" }),
        )
        .map_err(|error| error.envelope())?;
    if !outcome.created {
        return Ok(json_response(&outcome));
    }
    let operation_id = outcome
        .response
        .operation_id
        .expect("catalogue refresh operation id");
    if let Err(error) = spawn_refresh_worker(&state, operation_id, request.candidate_json) {
        let response = StoredResponse {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            body: json!({ "error": { "code": "CATALOGUE_REFRESH_FAILED", "message": error } }),
            operation_id: Some(operation_id),
        };
        state
            .idempotency
            .replace_response(
                &mut database.lock(),
                &idempotency,
                &response,
                |transaction| {
                    state
                        .jobs
                        .fail(transaction, operation_id, "CATALOGUE_REFRESH_FAILED")
                },
            )
            .map_err(|replace_error| replace_error.envelope())?;
        return Err((response.status, Json(response.body)));
    }
    Ok(json_response(&outcome))
}

pub fn spawn_refresh_worker(
    state: &AppState,
    operation_id: uuid::Uuid,
    candidate_json: String,
) -> Result<(), String> {
    let database = state
        .database
        .as_ref()
        .cloned()
        .ok_or_else(|| "database unavailable".to_owned())?;
    let service = state
        .catalogue_refresh
        .clone()
        .ok_or_else(|| "catalogue refresh unavailable".to_owned())?;
    state
        .jobs
        .spawn_leased(database, operation_id, move |lease| {
            match service.promote(&candidate_json, operation_id, &lease) {
                Ok(result) => {
                    lease.settle_succeeded(&result);
                }
                Err(error) => {
                    tracing::error!(%operation_id, %error, "catalogue refresh failed");
                    lease.settle_failed(error.code());
                }
            }
        })
        .map_err(|error| error.to_string())
}

#[cfg(test)]
#[path = "catalogue_api/tests.rs"]
mod tests;

mod refresh_service;
pub use refresh_service::{CatalogueRefreshError, CatalogueRefreshService};

mod catalogue_files;
pub use catalogue_files::recover_interrupted_promotion;
use catalogue_files::{
    previous_path, rollback_or, safe_load_catalogue, safe_read, stage_candidate, sync_directory,
    temporary_path, validate_parent, validate_regular_if_present,
};

#[path = "catalogue_api/profile_updates.rs"]
mod profile_updates;
use profile_updates::{
    check_profile_provenance, compatible_profile_update, update_installed_profiles,
};
