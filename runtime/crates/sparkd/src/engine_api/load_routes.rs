use super::*;

pub async fn preview_load_inference(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    Json(request): Json<LoadModelPreviewBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ModelOperate)
        .resource(format!("model/{}/load/preview", request.model_id))
        .check()?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| crate::models::internal_envelope("no database"))?;
    // Run blocking probes off the async executor and report task failures distinctly from absent runtime evidence.
    let container_report = match state.engine.manager.clone() {
        Some(manager) => {
            match tokio::task::spawn_blocking(move || manager.container_runtime()).await {
                Ok(report) => Some(report),
                Err(error) => {
                    tracing::warn!(%error, "container runtime probe could not run");
                    return Err(crate::models::internal_envelope(
                        "the container runtime could not be checked",
                    ));
                }
            }
        }
        None => None,
    };
    let external_inference = crate::workload_api::external_inference_guard(&state).await;
    let draft_result = load_preview_draft(
        &state,
        &request.model_id,
        &request.profile_id,
        request.replace_active,
        request.target.as_ref(),
        container_report.as_ref(),
        external_inference,
    );
    let (draft, _) = match draft_result {
        Ok(draft) => draft,
        Err(failure) => {
            let resource = format!("model/{}", request.model_id);
            let reason = crate::audit::response_code(&failure, "MODEL_PREVIEW_REFUSED");
            crate::audit::append_refusal(
                database,
                state.clock.as_ref(),
                principal.device_id,
                &principal.role,
                "/api/v1/inference/load/preview",
                "model.load.preview",
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
        .map_err(|error| crate::models::internal_envelope(&error.to_string()))?;
    let resource = format!("model/{}", request.model_id);
    let details = json!({
        "preview_digest": preview.get("preview_digest"),
        "profile_id": request.profile_id,
        "replace_active": request.replace_active,
    });
    crate::audit::append_committed(
        database,
        state.clock.as_ref(),
        &crate::audit::AuditDraft {
            actor_device_id: Some(principal.device_id),
            actor_role: Some(&principal.role),
            source_route: "/api/v1/inference/load/preview",
            action: "model.load.preview",
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

/// Queue a durable model load.
pub async fn load_inference(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    Json(payload): Json<LoadModelBody>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ModelOperate)
        .resource(format!("model/{}/load", payload.model_id))
        .check()?;
    let Some(manager) = &state.engine.manager else {
        return Err(crate::models::internal_envelope("engine unavailable"));
    };
    let Some(db) = &state.database else {
        return Err(crate::models::internal_envelope("no database"));
    };

    // Check stored replay before privileged probes; the guarded lookup remains authoritative if this early check races.
    {
        let mut conn = db.lock();
        if let Ok(Some(outcome)) = state.idempotency.lookup(&mut conn, &idempotency) {
            return Ok(json_response(&outcome));
        }
    }

    // A failed probe task must not become an absence of blockers.
    let container_report = match state.engine.manager.clone() {
        Some(manager) => {
            match tokio::task::spawn_blocking(move || manager.container_runtime()).await {
                Ok(report) => Some(report),
                Err(error) => {
                    tracing::warn!(%error, "container runtime probe could not run");
                    return Err(crate::models::internal_envelope(
                        "the container runtime could not be checked",
                    ));
                }
            }
        }
        None => None,
    };
    let external_inference = crate::workload_api::external_inference_guard(&state).await;

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
    let draft_result = load_preview_draft(
        &state,
        &payload.model_id,
        &payload.profile_id,
        payload.replace_active,
        payload.target.as_ref(),
        container_report.as_ref(),
        external_inference,
    );
    let (draft, recipe) = match draft_result {
        Ok(draft) => draft,
        Err(failure) => {
            let resource = format!("model/{}", payload.model_id);
            let reason = crate::audit::response_code(&failure, "MODEL_APPLY_REFUSED");
            crate::audit::append_refusal(
                db,
                state.clock.as_ref(),
                principal.device_id,
                &principal.role,
                "/api/v1/inference/load",
                "model.load",
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
        payload.accepted_preview_digest.as_deref(),
        &draft,
        &acceptance_key,
    ) {
        let resource = format!("model/{}", payload.model_id);
        crate::audit::append_refusal(
            db,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            "/api/v1/inference/load",
            "model.load",
            Some(&resource),
            idempotency.request_id,
            error.code(),
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err(error.envelope());
    }
    let outcome = {
        let mut conn = db.lock();
        let audit_resource = format!("model/{}", payload.model_id);
        let audit_details = json!({
            "profile_id": payload.profile_id,
            "replace_active": payload.replace_active,
        });
        state
            .idempotency
            .create_operation_audited(
                &mut conn,
                &idempotency,
                &state.jobs,
                "model.load",
                Some(&payload.model_id),
                &json!({ "model": payload.model_id, "profile": payload.profile_id }).to_string(),
                &principal.role,
                "/api/v1/inference/load",
                Some(&audit_resource),
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

    // Never hold the DB guard across spawn_load (it locks the same handle).
    if let Err(e) = manager.spawn_load(
        operation_id,
        &recipe,
        &payload.profile_id,
        payload.replace_active,
    ) {
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
