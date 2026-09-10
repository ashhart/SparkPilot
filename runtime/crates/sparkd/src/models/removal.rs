use super::*;

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RemoveModelBody {
    #[serde(default)]
    pub accepted_preview_digest: Option<String>,
}

pub(super) fn remove_preview_draft(
    state: &AppState,
    encoded_id: &str,
) -> Result<PreviewDraft, (StatusCode, Json<Value>)> {
    let id = decode_path_param(encoded_id);
    let inventory = state.models.as_ref().ok_or_else(internal_error)?.snapshot();
    let recipe = inventory.recipe(&id).ok_or_else(not_found)?;
    let conn = state.database.as_ref().ok_or_else(internal_error)?;
    let row = store::model_row(&conn.lock(), &id)
        .map_err(|error| internal_envelope(&error.to_string()))?
        .ok_or_else(not_found)?;
    let references = conn
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM inference_instances WHERE model_id = ?1",
            [&id],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|error| internal_envelope(&error.to_string()))?;
    let load_pending = store::has_non_terminal_operation(&conn.lock(), "model.load", &id)
        .map_err(|error| internal_envelope(&error.to_string()))?;
    let (target, cluster_available, cluster) =
        target_and_cluster(state).map_err(|error| internal_envelope(&error))?;
    let (active_available, active, _) =
        active_engine(state).map_err(|error| internal_envelope(&error.to_string()))?;
    let mut blockers = Vec::new();
    if row.install_state != "installed" {
        blockers.push(PreviewMessage::blocker(
            "MODEL_NOT_INSTALLED",
            "The selected model revision is not installed on this target.",
            "Refresh the library before trying to remove it.",
        ));
    }
    if active
        .as_ref()
        .is_some_and(|engine| engine.model_id == recipe.id())
    {
        blockers.push(PreviewMessage::blocker(
            "MODEL_ACTIVE",
            "The selected model is the active inference engine.",
            "Stop the active model, wait for the stop operation to succeed, and request a new removal preview.",
        ));
    }
    if !active_available {
        blockers.push(PreviewMessage::blocker(
            "ACTIVE_INFERENCE_EVIDENCE_UNAVAILABLE",
            "The runtime cannot prove that the selected model is inactive.",
            "Restore the engine service and request a new preview.",
        ));
    }
    let engine_transitioning = state
        .engine
        .manager
        .as_ref()
        .is_some_and(|manager| manager.is_transitioning());
    if engine_transitioning {
        blockers.push(PreviewMessage::blocker(
            "ENGINE_NOT_READY",
            "An engine transition is still in progress, so inactivity cannot be proven.",
            "Wait for the current operation to finish and request a new removal preview.",
        ));
    }
    if load_pending {
        blockers.push(PreviewMessage::blocker(
            "MODEL_LOAD_IN_PROGRESS",
            "A durable load operation may still activate the selected model.",
            "Wait for the load operation to reach a terminal state, stop the model if needed, and request a new removal preview.",
        ));
    }
    if references > 0 {
        blockers.push(PreviewMessage::blocker(
            "MODEL_REMOVE_REFERENCED",
            "Runtime history still references this model profile.",
            "Retain the model until the runtime can safely retire those references.",
        ));
    }
    let system = state.telemetry.system();
    let binding = PreviewBinding {
        target,
        recipe: Some(
            PreviewRecipeIdentity::from_recipe(recipe, None)
                .map_err(|error| internal_envelope(&error.to_string()))?,
        ),
        evidence: PreviewEvidence {
            external_workload_id: None,
            external_workload_evidence_digest: None,
            external_workload_healthy: None,
            remote: None,
            install_state: Some(row.install_state),
            installed_bytes: row.total_bytes.and_then(|bytes| u64::try_from(bytes).ok()),
            removable_bytes: Some(0),
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
            memory_pressure: Some(system.memory_pressure.api_name().to_owned()),
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
        action: "remove",
        action_key: action_key("remove", json!({ "model_id": recipe.id() })),
        binding,
        consequences: PreviewConsequences {
            model_to_stop: None,
            profile_to_stop: None,
            route_withdrawal: false,
            service_interruption: "none".to_owned(),
            // Remove inventory metadata only; retain shared content-addressed files.
            files_removed: Vec::new(),
            reinstall_required: true,
            alternative_profiles: None,
        },
        blockers,
        warnings: vec![PreviewMessage::warning(
            "MODEL_FILES_RETAINED",
            "Removal clears inventory metadata but retains shared content-addressed files.",
        )],
    })
}

/// Preview the consequences of model removal.
pub async fn preview_remove_model(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    RoutePath(id): RoutePath<String>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    if !principal.is_admin() {
        let resource = format!("model/{}", decode_path_param(&id));
        crate::audit::append_refusal(
            state.database.as_ref().ok_or_else(internal_error)?,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            "/api/v1/models/{model_id}/remove/preview",
            "model.remove.preview",
            Some(&resource),
            idempotency.request_id,
            "ROLE_FORBIDDEN",
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err((
            StatusCode::FORBIDDEN,
            Json(json!({ "error": { "code": "ROLE_FORBIDDEN", "message": "ROLE_FORBIDDEN" } })),
        ));
    }
    let database = state.database.as_ref().ok_or_else(internal_error)?;
    let draft = match remove_preview_draft(&state, &id) {
        Ok(draft) => draft,
        Err(failure) => {
            let resource = format!("model/{}", decode_path_param(&id));
            let reason = crate::audit::response_code(&failure, "MODEL_PREVIEW_REFUSED");
            crate::audit::append_refusal(
                database,
                state.clock.as_ref(),
                principal.device_id,
                &principal.role,
                "/api/v1/models/{model_id}/remove/preview",
                "model.remove.preview",
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
    let model_id = decode_path_param(&id);
    let resource = format!("model/{model_id}");
    let details = json!({ "preview_digest": preview.get("preview_digest") });
    crate::audit::append_committed(
        database,
        state.clock.as_ref(),
        &crate::audit::AuditDraft {
            actor_device_id: Some(principal.device_id),
            actor_role: Some(&principal.role),
            source_route: "/api/v1/models/{model_id}/remove/preview",
            action: "model.remove.preview",
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

/// Remove a model with administrator authority.
pub async fn remove_model(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    RoutePath(id): RoutePath<String>,
    Json(request): Json<RemoveModelBody>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    if !principal.is_admin() {
        let resource = format!("model/{}", decode_path_param(&id));
        crate::audit::append_refusal(
            state.database.as_ref().ok_or_else(internal_error)?,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            "/api/v1/models/{model_id}",
            "model.remove",
            Some(&resource),
            idempotency.request_id,
            "ROLE_FORBIDDEN",
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err((
            StatusCode::FORBIDDEN,
            Json(json!({ "error": { "code": "ROLE_FORBIDDEN", "message": "ROLE_FORBIDDEN" } })),
        ));
    }
    let Some(conn) = &state.database else {
        return Err(internal_error());
    };
    let _admission = state.idempotency.admission_guard();
    let replay = {
        let mut guard = conn.lock();
        state
            .idempotency
            .lookup(&mut guard, &idempotency)
            .map_err(|error| error.envelope())?
    };
    if let Some(outcome) = replay {
        return Ok(json_response(&outcome));
    }
    let draft = match remove_preview_draft(&state, &id) {
        Ok(draft) => draft,
        Err(failure) => {
            let resource = format!("model/{}", decode_path_param(&id));
            let reason = crate::audit::response_code(&failure, "MODEL_APPLY_REFUSED");
            crate::audit::append_refusal(
                conn,
                state.clock.as_ref(),
                principal.device_id,
                &principal.role,
                "/api/v1/models/{model_id}",
                "model.remove",
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
        let resource = format!("model/{}", decode_path_param(&id));
        crate::audit::append_refusal(
            conn,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            "/api/v1/models/{model_id}",
            "model.remove",
            Some(&resource),
            idempotency.request_id,
            error.code(),
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err(error.envelope());
    }
    // Validate identifiers without filesystem mutation and report retained shared files in the preview.
    let id = decode_path_param(&id);
    let audit_resource = format!("model/{id}");
    let mut guard = conn.lock();
    let outcome = state
        .idempotency
        .execute(&mut guard, &idempotency, |transaction| {
            let response = match store::remove_model_row(transaction, &id) {
                Ok(()) => {
                    let operation_id = state.jobs.create(
                        transaction,
                        "model.remove",
                        principal.device_id,
                        Some(&id),
                        &json!({ "model_id": id }).to_string(),
                    )?;
                    crate::audit::append(
                        transaction,
                        state.clock.as_ref(),
                        &crate::audit::AuditDraft {
                            actor_device_id: Some(principal.device_id),
                            actor_role: Some(&principal.role),
                            source_route: "/api/v1/models/{model_id}",
                            action: "model.remove",
                            resource: Some(&audit_resource),
                            result: "accepted",
                            operation_id: Some(operation_id),
                            request_id: idempotency.request_id,
                            details: &json!({ "shared_files_retained": true }),
                        },
                    )?;
                    state.jobs.succeed(
                        transaction,
                        operation_id,
                        &json!({ "model_id": id, "removed": true }),
                    )?;
                    let operation = state
                        .jobs
                        .get(transaction, operation_id)?
                        .ok_or(crate::store::StoreError::NotFound("operation"))?;
                    StoredResponse {
                        status: StatusCode::ACCEPTED,
                        body: serde_json::to_value(operation)
                            .map_err(|error| crate::store::StoreError::Sqlite(error.to_string()))?,
                        operation_id: Some(operation_id),
                    }
                }
                Err(crate::store::StoreError::NotFound(_)) => {
                    let (status, Json(body)) = not_found();
                    crate::audit::append(
                        transaction,
                        state.clock.as_ref(),
                        &crate::audit::AuditDraft {
                            actor_device_id: Some(principal.device_id),
                            actor_role: Some(&principal.role),
                            source_route: "/api/v1/models/{model_id}",
                            action: "model.remove",
                            resource: Some(&audit_resource),
                            result: "refused",
                            operation_id: None,
                            request_id: idempotency.request_id,
                            details: &json!({ "reason_code": "MODEL_NOT_FOUND" }),
                        },
                    )?;
                    StoredResponse {
                        status,
                        body,
                        operation_id: None,
                    }
                }
                Err(error) => return Err(error),
            };
            Ok(response)
        })
        .map_err(|error| error.envelope())?;
    if outcome.response.status.is_success() {
        Ok(json_response(&outcome))
    } else {
        Err(json_response(&outcome))
    }
}
