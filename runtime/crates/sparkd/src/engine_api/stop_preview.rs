use super::*;

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StopModelBody {
    #[serde(default)]
    pub force: bool,
    #[serde(default)]
    pub accepted_preview_digest: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StopModelPreviewBody {
    #[serde(default)]
    pub force: bool,
}

pub(super) fn stop_preview_draft(
    state: &AppState,
    force: bool,
) -> Result<PreviewDraft, (StatusCode, Json<Value>)> {
    let manager = state
        .engine
        .manager
        .as_ref()
        .ok_or_else(|| crate::models::internal_envelope("engine unavailable"))?;
    let (target, cluster_available, cluster) =
        target_and_cluster(state).map_err(|error| crate::models::internal_envelope(&error))?;
    let (active_available, active, active_recipe) = active_engine(state)
        .map_err(|error| crate::models::internal_envelope(&error.to_string()))?;
    let system = state.telemetry.system();
    let mut blockers = Vec::new();
    if active.is_none() {
        blockers.push(PreviewMessage::blocker(
            "MODEL_NOT_LOADED",
            "No inference engine is active on this target.",
            "Refresh the target state before trying to stop it.",
        ));
    }
    if !active_available {
        blockers.push(PreviewMessage::blocker(
            "ACTIVE_INFERENCE_EVIDENCE_UNAVAILABLE",
            "The runtime cannot prove which engine would stop.",
            "Restore the engine service and request a new preview.",
        ));
    }
    let engine_transitioning = manager.is_transitioning();
    if engine_transitioning {
        blockers.push(PreviewMessage::blocker(
            "ENGINE_NOT_READY",
            "The engine is already changing state.",
            "Wait for the current operation to finish and request a new preview.",
        ));
    }
    let consequences = active
        .as_ref()
        .map(|active| PreviewConsequences {
            model_to_stop: Some(active.model_id.clone()),
            profile_to_stop: Some(active.profile_id.clone()),
            route_withdrawal: true,
            service_interruption: "until_reloaded".to_owned(),
            files_removed: Vec::new(),
            reinstall_required: false,
            alternative_profiles: None,
        })
        .unwrap_or_default();
    let mut warnings = Vec::new();
    if force {
        warnings.push(PreviewMessage::warning(
            "FORCED_STOP_REQUESTED",
            "The runtime may stop the active engine without a graceful drain.",
        ));
    }
    let binding = PreviewBinding {
        target,
        recipe: active_recipe,
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
            disk_free_bytes: Some(system.disk_free_bytes),
            expected_disk_free_after_bytes: None,
            required_memory_bytes: None,
            available_memory_bytes: Some(system.unified_memory_available_bytes),
            system_reserve_bytes: None,
            expected_memory_headroom_bytes: None,
            launch_memory: None,
            memory_pressure: Some(
                crate::guard::observed_pressure(state.guard.as_ref(), &system)
                    .api_name()
                    .to_owned(),
            ),
            memory_admission: None,
            profile_failure_code: None,
            active_inference_available: active_available,
            engine_transitioning,
            active_engine: active,
            cluster_membership_available: cluster_available,
            cluster_membership_source: cluster_available.then(|| "runtime_cache".to_owned()),
            cluster,
        },
    };
    Ok(PreviewDraft {
        action: "stop",
        action_key: action_key("stop", json!({ "force": force })),
        binding,
        consequences,
        blockers,
        warnings,
    })
}

pub async fn preview_unload_inference(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    Json(request): Json<StopModelPreviewBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ModelOperate)
        .resource("inference/unload/preview")
        .check()?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| crate::models::internal_envelope("no database"))?;
    let draft = match stop_preview_draft(&state, request.force) {
        Ok(draft) => draft,
        Err(failure) => {
            let reason = crate::audit::response_code(&failure, "MODEL_PREVIEW_REFUSED");
            crate::audit::append_refusal(
                database,
                state.clock.as_ref(),
                principal.device_id,
                &principal.role,
                "/api/v1/inference/unload/preview",
                "model.unload.preview",
                Some("inference/active"),
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
        .map_err(|error| crate::models::internal_envelope(&error.to_string()))?;
    let details = json!({
        "preview_digest": preview.get("preview_digest"),
        "force": request.force,
    });
    crate::audit::append_committed(
        database,
        state.clock.as_ref(),
        &crate::audit::AuditDraft {
            actor_device_id: Some(principal.device_id),
            actor_role: Some(&principal.role),
            source_route: "/api/v1/inference/unload/preview",
            action: "model.unload.preview",
            resource: Some("inference/active"),
            result: "accepted",
            operation_id: None,
            request_id: idempotency.request_id,
            details: &details,
        },
    )
    .map_err(crate::audit::unavailable_envelope)?;
    Ok(Json(preview))
}

/// Queue a durable drain and unload.
pub async fn unload_inference(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    Json(payload): Json<StopModelBody>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ModelOperate)
        .resource("inference/unload")
        .check()?;
    let Some(manager) = &state.engine.manager else {
        return Err(crate::models::internal_envelope("engine unavailable"));
    };
    let Some(db) = &state.database else {
        return Err(crate::models::internal_envelope("no database"));
    };
    let _admission = state.idempotency.admission_guard();
    let replay = {
        let mut conn = db.lock();
        state
            .idempotency
            .lookup(&mut conn, &idempotency)
            .map_err(|error| error.envelope())?
    };
    if let Some(outcome) = replay {
        return Ok(json_response(&outcome));
    }
    let draft = match stop_preview_draft(&state, payload.force) {
        Ok(draft) => draft,
        Err(failure) => {
            let reason = crate::audit::response_code(&failure, "MODEL_APPLY_REFUSED");
            crate::audit::append_refusal(
                db,
                state.clock.as_ref(),
                principal.device_id,
                &principal.role,
                "/api/v1/inference/unload",
                "model.unload",
                Some("inference/active"),
                idempotency.request_id,
                &reason,
            )
            .map_err(crate::audit::unavailable_envelope)?;
            return Err(failure);
        }
    };
    let acceptance_key = format!("{}:{}", idempotency.device_id, idempotency.key);
    if let Err(error) = state.previews.validate(
        payload.accepted_preview_digest.as_deref(),
        &draft,
        &acceptance_key,
    ) {
        crate::audit::append_refusal(
            db,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            "/api/v1/inference/unload",
            "model.unload",
            Some("inference/active"),
            idempotency.request_id,
            error.code(),
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err(error.envelope());
    }
    let outcome = {
        let mut conn = db.lock();
        let audit_details = json!({ "force": payload.force });
        state
            .idempotency
            .create_operation_audited(
                &mut conn,
                &idempotency,
                &state.jobs,
                "model.unload",
                None,
                &json!({ "force": payload.force }).to_string(),
                &principal.role,
                "/api/v1/inference/unload",
                Some("inference/active"),
                &audit_details,
            )
            .map_err(|error| error.envelope())?
    };
    if !outcome.created {
        return Ok(json_response(&outcome));
    }
    let operation_id = outcome
        .response
        .operation_id
        .expect("operation submissions always carry an operation id");

    // Never hold the DB guard across spawn_unload (it locks the same handle).
    if let Err(e) = manager.spawn_unload(operation_id, payload.force) {
        let (status, Json(body)) = e.envelope();
        let replacement = StoredResponse {
            status,
            body: body.clone(),
            operation_id: Some(operation_id),
        };
        let mut conn = db.lock();
        state
            .idempotency
            .replace_response(&mut conn, &idempotency, &replacement, |transaction| {
                state.jobs.fail(transaction, operation_id, e.code())
            })
            .map_err(|error| error.envelope())?;
        return Err((status, Json(body)));
    }
    Ok(json_response(&outcome))
}
