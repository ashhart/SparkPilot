//! Let only owners reenable the exact reviewed unsafe profile; bind failure state and measurements so changed evidence invalidates apply.

use axum::extract::{Extension, Path as RoutePath, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Json;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::auth::{AuthenticatedRequest, Principal};
use crate::idempotency::{IdempotencyRequest, json_response};
use crate::models::{decode_path_param, internal_envelope};
use crate::preview::{
    PreviewBinding, PreviewConsequences, PreviewDraft, PreviewEvidence, PreviewMessage,
    PreviewRecipeIdentity, action_key, active_engine, target_and_cluster,
};
use crate::state::AppState;

const PREVIEW_ROUTE: &str = "/api/v1/models/{model_id}/profiles/{profile_id}/re-enable/preview";
const APPLY_ROUTE: &str = "/api/v1/models/{model_id}/profiles/{profile_id}/re-enable";
const PREVIEW_ACTION: &str = "model.profile.reenable.preview";
const APPLY_ACTION: &str = "model.profile.reenable";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReenableProfileBody {
    pub accepted_preview_digest: String,
}

fn internal_error() -> (StatusCode, Json<Value>) {
    internal_envelope("no database")
}

fn envelope(status: StatusCode, code: &str, message: &str) -> (StatusCode, Json<Value>) {
    (
        status,
        Json(json!({ "error": { "code": code, "message": message } })),
    )
}

/// Include the exact profile identity in authorization and audit resources.
fn resource_for(model_id: &str, profile_id: &str) -> String {
    format!("model/{model_id}/profile/{profile_id}")
}

/// Require owner authority above administrator for overriding a guard safety decision, and audit refusals.
fn require_owner(
    state: &AppState,
    principal: &Principal,
    idempotency: &IdempotencyRequest,
    route: &'static str,
    action: &'static str,
    resource: &str,
) -> Result<(), (StatusCode, Json<Value>)> {
    if principal.role == "owner" {
        return Ok(());
    }
    crate::audit::append_refusal(
        state.database.as_ref().ok_or_else(internal_error)?,
        state.clock.as_ref(),
        principal.device_id,
        &principal.role,
        route,
        action,
        Some(resource),
        idempotency.request_id,
        "ROLE_FORBIDDEN",
    )
    .map_err(crate::audit::unavailable_envelope)?;
    Err(envelope(
        StatusCode::FORBIDDEN,
        "ROLE_FORBIDDEN",
        "owner access is required to re-enable a profile",
    ))
}

/// Derive preview evidence server-side and rebuild it from apply path parameters before comparing digests.
fn reenable_preview_draft(
    state: &AppState,
    encoded_model: &str,
    encoded_profile: &str,
) -> Result<PreviewDraft, (StatusCode, Json<Value>)> {
    let model_id = decode_path_param(encoded_model);
    let profile_id = decode_path_param(encoded_profile);

    // Review only profiles present in the verified catalogue; a database id alone is insufficient.
    let inventory = state.models.as_ref().ok_or_else(internal_error)?.snapshot();
    let recipe = inventory.recipe(&model_id).ok_or_else(|| {
        envelope(
            StatusCode::NOT_FOUND,
            "MODEL_NOT_FOUND",
            "the model is not in this Spark's verified catalogue",
        )
    })?;
    if !recipe.profiles.iter().any(|p| p.id == profile_id) {
        return Err(envelope(
            StatusCode::BAD_REQUEST,
            "PROFILE_NOT_FOUND",
            "the selected profile does not belong to this model",
        ));
    }

    let conn = state.database.as_ref().ok_or_else(internal_error)?;
    let (is_unsafe, failure_code, measured_peak_bytes) = {
        let guard = conn.lock();
        let is_unsafe = crate::guard::profile_is_unsafe(&guard, &model_id, &profile_id)
            .map_err(|error| internal_envelope(&error.to_string()))?;
        let (code, peak) = crate::guard::recorded_failure(&guard, &model_id, &profile_id)
            .map_err(|error| internal_envelope(&error.to_string()))?;
        (is_unsafe, code, peak)
    };

    let mut blockers = Vec::new();
    if !is_unsafe {
        // Refuse already-safe profiles so a reviewed reenable action cannot silently become a no-op.
        blockers.push(PreviewMessage::blocker(
            "MODEL_PROFILE_ALREADY_SAFE",
            "This profile is not disabled, so there is nothing to re-enable.",
            "Refresh the model details; no action is required.",
        ));
    }

    let (target, cluster_available, cluster) =
        target_and_cluster(state).map_err(|error| internal_envelope(&error))?;
    let (active_available, active, _) =
        active_engine(state).map_err(|error| internal_envelope(&error.to_string()))?;
    let system = state.telemetry.system();

    let binding = PreviewBinding {
        target,
        // Bind profile identity, recipe digest and signing key to the exact signed revision.
        recipe: Some(
            PreviewRecipeIdentity::from_recipe(recipe, Some(&profile_id))
                .map_err(|error| internal_envelope(&error.to_string()))?,
        ),
        evidence: PreviewEvidence {
            external_workload_id: None,
            external_workload_evidence_digest: None,
            external_workload_healthy: None,
            remote: None,
            install_state: None,
            installed_bytes: None,
            removable_bytes: None,
            download_bytes: None,
            locally_reusable_bytes: None,
            required_disk_bytes: None,
            disk_free_bytes: None,
            expected_disk_free_after_bytes: None,
            required_memory_bytes: measured_peak_bytes,
            available_memory_bytes: Some(system.unified_memory_available_bytes),
            system_reserve_bytes: None,
            expected_memory_headroom_bytes: None,
            launch_memory: None,
            memory_pressure: Some(system.memory_pressure.api_name().to_owned()),
            // Expose guard failure codes beside the typed admission decision without widening its closed vocabulary.
            memory_admission: is_unsafe.then(|| "deny_profile_unsafe".to_owned()),
            profile_failure_code: failure_code.clone(),
            active_inference_available: active_available,
            engine_transitioning: state
                .engine
                .manager
                .as_ref()
                .is_some_and(|manager| manager.is_transitioning()),
            active_engine: active,
            cluster_membership_available: cluster_available,
            cluster_membership_source: cluster_available.then(|| "runtime_cache".to_owned()),
            cluster,
        },
    };

    Ok(PreviewDraft {
        action: "profile.reenable",
        // Bind action identity and reviewed failure state so another profile or changed unsafe evidence cannot reuse the digest.
        action_key: action_key(
            "profile.reenable",
            json!({
                "model_id": model_id,
                "profile_id": profile_id,
                "unsafe": is_unsafe,
                "last_failure_code": failure_code,
                "measured_peak_bytes": measured_peak_bytes,
            }),
        ),
        binding,
        consequences: PreviewConsequences {
            model_to_stop: None,
            profile_to_stop: None,
            route_withdrawal: false,
            service_interruption: "none".to_owned(),
            files_removed: Vec::new(),
            reinstall_required: false,
            alternative_profiles: None,
        },
        blockers,
        warnings: vec![PreviewMessage::warning(
            "MODEL_PROFILE_REENABLE_RESTORES_ADMISSION",
            "Re-enabling restores this profile to admission with its recorded measurement; \
             the condition that caused the failure is not re-checked.",
        )],
    })
}

/// `POST /api/v1/models/{modelId}/profiles/{profileId}/re-enable/preview`
pub async fn preview_reenable_model_profile(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    RoutePath((model, profile)): RoutePath<(String, String)>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let resource = resource_for(&decode_path_param(&model), &decode_path_param(&profile));
    require_owner(
        &state,
        &principal,
        &idempotency,
        PREVIEW_ROUTE,
        PREVIEW_ACTION,
        &resource,
    )?;
    let database = state.database.as_ref().ok_or_else(internal_error)?;
    let draft = match reenable_preview_draft(&state, &model, &profile) {
        Ok(draft) => draft,
        Err(failure) => {
            let reason = crate::audit::response_code(&failure, "MODEL_PREVIEW_REFUSED");
            crate::audit::append_refusal(
                database,
                state.clock.as_ref(),
                principal.device_id,
                &principal.role,
                PREVIEW_ROUTE,
                PREVIEW_ACTION,
                Some(&resource),
                idempotency.request_id,
                &reason,
            )
            .map_err(crate::audit::unavailable_envelope)?;
            return Err(failure);
        }
    };
    let preview = state
        .previews
        .issue(&draft)
        .map_err(|error| internal_envelope(&error.to_string()))?;
    let details = json!({ "blockers": draft.blockers.len() });
    crate::audit::append_committed(
        database,
        state.clock.as_ref(),
        &crate::audit::AuditDraft {
            actor_device_id: Some(principal.device_id),
            actor_role: Some(&principal.role),
            source_route: PREVIEW_ROUTE,
            action: PREVIEW_ACTION,
            resource: Some(&resource),
            result: "accepted",
            operation_id: None,
            request_id: idempotency.request_id,
            details: &details,
        },
    )
    .map_err(crate::audit::unavailable_envelope)?;
    Ok(Json(preview))
}

/// `POST /api/v1/models/{modelId}/profiles/{profileId}/re-enable`
pub async fn reenable_model_profile(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    RoutePath((model, profile)): RoutePath<(String, String)>,
    Json(body): Json<ReenableProfileBody>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let model_id = decode_path_param(&model);
    let profile_id = decode_path_param(&profile);
    let resource = resource_for(&model_id, &profile_id);
    require_owner(
        &state,
        &principal,
        &idempotency,
        APPLY_ROUTE,
        APPLY_ACTION,
        &resource,
    )?;
    let database = state.database.as_ref().ok_or_else(internal_error)?;

    // Return accepted replay receipts before requesting another presence gesture.
    let _admission = state.idempotency.admission_guard();
    let replay = {
        let mut conn = database.lock();
        state
            .idempotency
            .lookup(&mut conn, &idempotency)
            .map_err(|error| error.envelope())?
    };
    if let Some(outcome) = replay {
        return Ok(json_response(&outcome));
    }

    let presence_key = {
        let conn = database.lock();
        crate::store::load_presence_key_by_device_id(&conn, &principal.device_id)
            .map_err(|error| internal_envelope(&error.to_string()))?
    };
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
            APPLY_ROUTE,
            APPLY_ACTION,
            Some(&resource),
            idempotency.request_id,
            error.code(),
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err(envelope(
            StatusCode::FORBIDDEN,
            error.code(),
            "fresh user presence is required to re-enable a profile",
        ));
    }

    // Rebuild from this request's parameters; the client preview body cannot supply trusted evidence.
    let draft = reenable_preview_draft(&state, &model, &profile)?;
    let acceptance_key = format!("{}:{}", idempotency.device_id, idempotency.key);
    if let Err(error) = state.previews.validate(
        Some(body.accepted_preview_digest.as_str()),
        &draft,
        &acceptance_key,
    ) {
        crate::audit::append_refusal(
            database,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            APPLY_ROUTE,
            APPLY_ACTION,
            Some(&resource),
            idempotency.request_id,
            error.code(),
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err(error.envelope());
    }

    let details = json!({ "model_id": model_id, "profile_id": profile_id });
    let outcome = {
        let mut conn = database.lock();
        state
            .idempotency
            .create_noncancellable_operation_audited(
                &mut conn,
                &idempotency,
                &state.jobs,
                APPLY_ACTION,
                Some(&resource),
                &details.to_string(),
                &principal.role,
                APPLY_ROUTE,
                Some(&resource),
                &details,
            )
            .map_err(|error| error.envelope())?
    };
    if !outcome.created {
        return Ok(json_response(&outcome));
    }
    let operation_id = outcome.response.operation_id.expect("new operation id");

    let worker_db = database.clone();
    let worker_model = model_id.clone();
    let worker_profile = profile_id.clone();
    state
        .jobs
        .spawn_leased(database.clone(), operation_id, move |lease| {
            let cleared = {
                let conn = worker_db.lock();
                crate::guard::clear_profile_unsafe(&conn, &worker_model, &worker_profile)
            };
            match cleared {
                Ok(()) => {
                    lease.settle_succeeded(&json!({
                        "model_id": worker_model,
                        "profile_id": worker_profile,
                        "safe": true,
                    }));
                }
                Err(error) => {
                    tracing::error!(%error, "profile re-enable persistence failed");
                    lease.settle_failed("MODEL_PROFILE_REENABLE_FAILED");
                }
            }
        })
        .map_err(|error| internal_envelope(&error.to_string()))?;

    Ok(json_response(&outcome))
}
