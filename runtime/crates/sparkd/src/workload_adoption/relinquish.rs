use super::*;

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RelinquishRequest {
    pub accepted_preview_digest: String,
}

pub(super) fn relinquish_draft(
    state: &AppState,
    workload_id: &str,
) -> Result<(PreviewDraft, String), (StatusCode, Json<Value>)> {
    let manager = state.engine.manager.as_ref().ok_or_else(|| {
        error(
            StatusCode::SERVICE_UNAVAILABLE,
            "ENGINE_UNAVAILABLE",
            "The model lifecycle controller is unavailable.",
        )
    })?;
    let instance_id = manager
        .validate_relinquish_adopted(workload_id)
        .map_err(|failure| failure.envelope())?;
    let view = manager.view().ok_or_else(|| {
        error(
            StatusCode::NOT_FOUND,
            "WORKLOAD_NOT_ADOPTED",
            "This workload is not managed by SparkPilot.",
        )
    })?;
    let (target, cluster_available, cluster) = target_and_cluster(state).map_err(|_| {
        error(
            StatusCode::SERVICE_UNAVAILABLE,
            "CLUSTER_STATE_UNAVAILABLE",
            "Cluster state could not be read.",
        )
    })?;
    let recipe =
        PreviewRecipeIdentity::from_recipe(&view.recipe, Some(&view.profile_id)).map_err(|_| {
            error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "INTERNAL",
                "Recipe identity could not be encoded.",
            )
        })?;
    let evidence_digest = crate::crypto::sha256_hex(
        format!(
            "{workload_id}:{instance_id}:{}:{}",
            view.model_id, view.profile_id
        )
        .as_bytes(),
    );
    Ok((
        PreviewDraft {
            action: "workload.relinquish",
            action_key: action_key(
                "workload.relinquish",
                json!({ "workload_id": workload_id, "instance_id": instance_id }),
            ),
            binding: PreviewBinding {
                target,
                recipe: Some(recipe),
                evidence: PreviewEvidence {
                    external_workload_id: Some(workload_id.to_owned()),
                    external_workload_evidence_digest: Some(evidence_digest),
                    external_workload_healthy: None,
                    remote: None,
                    install_state: Some("installed".into()),
                    installed_bytes: None,
                    removable_bytes: None,
                    download_bytes: None,
                    locally_reusable_bytes: None,
                    required_disk_bytes: None,
                    disk_free_bytes: None,
                    expected_disk_free_after_bytes: None,
                    required_memory_bytes: None,
                    available_memory_bytes: None,
                    system_reserve_bytes: None,
                    expected_memory_headroom_bytes: None,
                    launch_memory: None,
                    memory_pressure: None,
                    memory_admission: None,
                    profile_failure_code: None,
                    active_inference_available: true,
                    engine_transitioning: false,
                    active_engine: None,
                    cluster_membership_available: cluster_available,
                    cluster_membership_source: cluster_available.then(|| "runtime_cache".into()),
                    cluster,
                },
            },
            consequences: PreviewConsequences {
                model_to_stop: None,
                profile_to_stop: None,
                route_withdrawal: true,
                service_interruption: "none".into(),
                files_removed: Vec::new(),
                reinstall_required: false,
                alternative_profiles: None,
            },
            blockers: Vec::new(),
            warnings: vec![
                PreviewMessage::warning(
                    "CONTAINER_LEFT_RUNNING",
                    "The external container, model files, mounts and endpoint stay running and unchanged.",
                ),
                PreviewMessage::warning(
                    "SPARKPILOT_ROUTE_WITHDRAWN",
                    "SparkPilot stops proxying chat to this workload after it removes its ownership record.",
                ),
            ],
        },
        instance_id,
    ))
}

pub async fn preview_relinquish(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Path(workload_id): Path<String>,
    idempotency: IdempotencyRequest,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    require_administrator(&principal)?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| error(StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL", "no database"))?;
    let (draft, _) = relinquish_draft(&state, &workload_id)?;
    let preview = state.previews.issue(&draft).map_err(|_| {
        error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL",
            "The relinquish review could not be issued.",
        )
    })?;
    crate::audit::append_committed(
        database,
        state.clock.as_ref(),
        &crate::audit::AuditDraft {
            actor_device_id: Some(principal.device_id),
            actor_role: Some(&principal.role),
            source_route: "/api/v1/workloads/{workload_id}/relinquish/preview",
            action: "workload.relinquish.preview",
            resource: Some(&workload_id),
            result: "accepted",
            operation_id: None,
            request_id: idempotency.request_id,
            details: &json!({ "preview_digest": preview.get("preview_digest") }),
        },
    )
    .map_err(crate::audit::unavailable_envelope)?;
    Ok(Json(preview))
}

pub async fn relinquish(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    Path(workload_id): Path<String>,
    headers: HeaderMap,
    idempotency: IdempotencyRequest,
    Json(request): Json<RelinquishRequest>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
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
    let _admission = state.idempotency.admission_guard();
    if let Some(outcome) = state
        .idempotency
        .lookup(&mut database.lock(), &idempotency)
        .map_err(|failure| failure.envelope())?
    {
        return Ok(Json(outcome.response.body));
    }
    let (draft, instance_id) = relinquish_draft(&state, &workload_id)?;
    state
        .previews
        .validate(
            Some(&request.accepted_preview_digest),
            &draft,
            &format!("{}:{}", idempotency.device_id, idempotency.key),
        )
        .map_err(|failure| failure.envelope())?;
    verify_presence(&state, &principal, &headers, &authenticated_request)?;
    let reserved_instance_id = manager
        .begin_relinquish_adopted(&workload_id)
        .map_err(|failure| failure.envelope())?;
    if reserved_instance_id != instance_id {
        manager.abort_relinquish_adopted(&workload_id);
        return Err(error(
            StatusCode::CONFLICT,
            "PREVIEW_STALE",
            "The managed workload changed after review.",
        ));
    }
    let body = json!({
        "workload_id": workload_id,
        "ownership": "external_observed",
        "container_changed": false,
    });
    let outcome = match state
        .idempotency
        .execute(&mut database.lock(), &idempotency, |transaction| {
            let changed = transaction.execute(
                "DELETE FROM inference_instances WHERE id = ?1 AND container_id = ?2 AND json_extract(metadata_json, '$.ownership_origin') = 'external_adoption'",
                rusqlite::params![instance_id, workload_id],
            )?;
            if changed != 1 {
                return Err(crate::store::StoreError::NotFound("adopted workload"));
            }
            crate::audit::append(
                transaction,
                state.clock.as_ref(),
                &crate::audit::AuditDraft {
                    actor_device_id: Some(principal.device_id),
                    actor_role: Some(&principal.role),
                    source_route: RELINQUISH_ROUTE,
                    action: "workload.relinquish",
                    resource: Some(&workload_id),
                    result: "accepted",
                    operation_id: None,
                    request_id: idempotency.request_id,
                    details: &json!({ "container_changed": false }),
                },
            )?;
            Ok(StoredResponse {
                status: StatusCode::OK,
                body: body.clone(),
                operation_id: None,
            })
        }) {
        Ok(outcome) => outcome,
        Err(failure) => {
            manager.abort_relinquish_adopted(&workload_id);
            return Err(failure.envelope());
        }
    };
    manager
        .finish_relinquish_adopted(&workload_id)
        .map_err(|failure| failure.envelope())?;
    Ok(Json(outcome.response.body))
}
