use super::*;

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AdoptionPreviewRequest {
    pub model_id: String,
    pub profile_id: String,
}

pub(super) fn recipe_and_policy(
    state: &AppState,
    workload_id: &str,
    model_id: &str,
    profile_id: &str,
) -> Result<(spark_models::ModelRecipe, ModelAdoptionPolicy), (StatusCode, Json<Value>)> {
    if !spark_privd::adoption::valid_workload_id(workload_id) {
        return Err(error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "WORKLOAD_ID_INVALID",
            "The external workload id is invalid.",
        ));
    }
    let inventory = state
        .models
        .as_ref()
        .ok_or_else(|| {
            error(
                StatusCode::SERVICE_UNAVAILABLE,
                "CATALOGUE_UNAVAILABLE",
                "The signed model catalogue is unavailable.",
            )
        })?
        .snapshot();
    let recipe = inventory.recipe(model_id).cloned().ok_or_else(|| {
        error(
            StatusCode::NOT_FOUND,
            "MODEL_NOT_FOUND",
            "The selected signed model recipe is unavailable.",
        )
    })?;
    let profile = recipe
        .profiles
        .iter()
        .find(|profile| profile.id == profile_id)
        .ok_or_else(|| {
            error(
                StatusCode::UNPROCESSABLE_ENTITY,
                "MODEL_PROFILE_INVALID",
                "The selected profile is not in this signed recipe.",
            )
        })?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| error(StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL", "no database"))?;
    let row = crate::store::model_row(&database.lock(), model_id)
        .map_err(|_| {
            error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "INTERNAL",
                "model inventory unavailable",
            )
        })?
        .ok_or_else(|| {
            error(
                StatusCode::NOT_FOUND,
                "MODEL_NOT_FOUND",
                "The selected model is not installed.",
            )
        })?;
    if row.install_state != "installed"
        || row.recipe_revision != recipe.metadata.revision
        || row.source_revision != recipe.source.revision
    {
        return Err(error(
            StatusCode::CONFLICT,
            "MODEL_REVISION_NOT_INSTALLED",
            "Install the exact signed model revision before reviewing adoption.",
        ));
    }
    let snapshot = crate::model_paths::snapshot_path(
        &state.storage.models,
        recipe.id(),
        &recipe.source.revision,
    )
    .map_err(|_| {
        error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "MODEL_RECIPE_INVALID",
            "The signed model path is invalid.",
        )
    })?;
    Ok((
        recipe.clone(),
        ModelAdoptionPolicy {
            workload_id: workload_id.to_owned(),
            recipe_id: recipe.id().to_owned(),
            profile_id: profile.id.clone(),
            image_digest: recipe.engine.image.clone(),
            served_name: recipe.engine.served_name.clone(),
            model_snapshot: snapshot.to_string_lossy().into_owned(),
            gpu_memory_utilisation_milli: (profile.gpu_memory_utilisation * 1000.0).round() as u16,
            max_model_length: profile.max_model_length,
            max_sequences: profile.max_sequences,
            max_batched_tokens: profile.max_batched_tokens,
            allow_network_during_inference: recipe.security.allow_network_during_inference,
        },
    ))
}

pub(super) async fn inspect_workload(
    state: &AppState,
    policy: ModelAdoptionPolicy,
) -> Result<Option<AdoptionInspection>, (StatusCode, Json<Value>)> {
    let Some(privileged) = state.privileged.clone() else {
        return Ok(None);
    };
    let response = tokio::task::spawn_blocking(move || {
        privileged.call_bounded(
            PrivilegedOperation::InspectModelAdoption {
                request_id: uuid::Uuid::new_v4(),
                policy,
            },
            INSPECTION_TIMEOUT,
        )
    })
    .await
    .map_err(|_| {
        error(
            StatusCode::SERVICE_UNAVAILABLE,
            "WORKLOAD_INSPECTION_UNAVAILABLE",
            "The container inspection did not finish.",
        )
    })?
    .map_err(|_| {
        error(
            StatusCode::SERVICE_UNAVAILABLE,
            "WORKLOAD_INSPECTION_UNAVAILABLE",
            "The container could not be inspected.",
        )
    })?;
    if !response.accepted || response.code != "adoption_inspected" {
        return Ok(None);
    }
    serde_json::from_value(response.details)
        .map(Some)
        .map_err(|_| {
            error(
                StatusCode::SERVICE_UNAVAILABLE,
                "WORKLOAD_INSPECTION_UNAVAILABLE",
                "The container inspection response was invalid.",
            )
        })
}

pub(super) async fn health_matches(host_port: u16, served_name: &str) -> bool {
    let Ok(client) = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_millis(250))
        .timeout(Duration::from_millis(750))
        .build()
    else {
        return false;
    };
    let health = client
        .get(format!("http://127.0.0.1:{host_port}/health"))
        .send()
        .await
        .is_ok_and(|response| response.status().is_success());
    if !health {
        return false;
    }
    let Ok(response) = client
        .get(format!("http://127.0.0.1:{host_port}/v1/models"))
        .send()
        .await
    else {
        return false;
    };
    if !response.status().is_success() {
        return false;
    }
    if response
        .content_length()
        .is_some_and(|length| length > MAX_MODEL_LIST_BYTES as u64)
    {
        return false;
    }
    let mut bytes = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let Ok(chunk) = chunk else { return false };
        if bytes.len().saturating_add(chunk.len()) > MAX_MODEL_LIST_BYTES {
            return false;
        }
        bytes.extend_from_slice(&chunk);
    }
    let Ok(body) = serde_json::from_slice::<Value>(&bytes) else {
        return false;
    };
    let aliases = body
        .get("data")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.get("id").and_then(Value::as_str))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    aliases == [served_name]
}

pub(super) async fn adoption_draft(
    state: &AppState,
    workload_id: &str,
    model_id: &str,
    profile_id: &str,
) -> Result<(PreviewDraft, spark_models::ModelRecipe, Option<u16>), (StatusCode, Json<Value>)> {
    let (recipe, policy) = recipe_and_policy(state, workload_id, model_id, profile_id)?;
    let mut blockers = Vec::new();
    if !matches!(
        recipe.engine.recipe.as_str(),
        "vllm-dgx-spark-2026-08" | "vllm-dgx-spark-2026-09"
    ) {
        blockers.push(PreviewMessage::blocker(
            "ENGINE_RECIPE_UNSUPPORTED",
            "Only the signed Spark vLLM container recipe can be adopted in this build.",
            "Keep this workload externally managed.",
        ));
    }
    if policy.allow_network_during_inference {
        blockers.push(PreviewMessage::blocker(
            "NETWORK_POLICY_UNSUPPORTED",
            "This recipe permits inference egress, which the in-place adoption controller does not support.",
            "Keep this workload externally managed.",
        ));
    }
    let inspection = if blockers.is_empty() {
        inspect_workload(state, policy).await?
    } else {
        None
    };
    if let Some(inspection) = &inspection {
        for code in &inspection.mismatch_codes {
            blockers.push(mismatch_blocker(code));
        }
    } else if blockers.is_empty() {
        blockers.push(PreviewMessage::blocker(
            "WORKLOAD_INSPECTION_UNAVAILABLE",
            "SparkPilot could not establish the container's exact configuration.",
            "Leave the workload running and review it again after container inspection recovers.",
        ));
    }
    let host_port = inspection
        .as_ref()
        .and_then(|inspection| inspection.host_port);
    let healthy = if inspection
        .as_ref()
        .is_some_and(|inspection| inspection.eligible)
    {
        match host_port {
            Some(port) => health_matches(port, &recipe.engine.served_name).await,
            None => false,
        }
    } else {
        false
    };
    if inspection
        .as_ref()
        .is_some_and(|inspection| inspection.eligible)
        && !healthy
    {
        blockers.push(PreviewMessage::blocker(
            "WORKLOAD_UNHEALTHY",
            "The exact container matched, but its loopback health and model alias could not be verified.",
            "Restore the external service, then request a new review.",
        ));
    }
    let manager = state.engine.manager.as_ref().ok_or_else(|| {
        error(
            StatusCode::SERVICE_UNAVAILABLE,
            "ENGINE_UNAVAILABLE",
            "The model lifecycle controller is unavailable.",
        )
    })?;
    if manager.view().is_some() || manager.is_transitioning() {
        blockers.push(PreviewMessage::blocker(
            "ENGINE_ACTIVE",
            "SparkPilot already controls an active model lifecycle on this Spark.",
            "Unload the managed model before reviewing adoption.",
        ));
    }
    let (target, cluster_available, cluster) = target_and_cluster(state).map_err(|_| {
        error(
            StatusCode::SERVICE_UNAVAILABLE,
            "CLUSTER_STATE_UNAVAILABLE",
            "Cluster state could not be read.",
        )
    })?;
    let (active_available, active, _) = active_engine(state).map_err(|_| {
        error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL",
            "Active model state could not be read.",
        )
    })?;
    let evidence_digest = inspection
        .as_ref()
        .map(|inspection| inspection.evidence_digest.clone());
    Ok((
        PreviewDraft {
            action: "workload.adopt",
            action_key: action_key(
                "workload.adopt",
                json!({
                    "workload_id": workload_id,
                    "model_id": model_id,
                    "profile_id": profile_id,
                }),
            ),
            binding: PreviewBinding {
                target,
                recipe: Some(
                    PreviewRecipeIdentity::from_recipe(&recipe, Some(profile_id)).map_err(
                        |_| {
                            error(
                                StatusCode::INTERNAL_SERVER_ERROR,
                                "INTERNAL",
                                "Recipe identity could not be encoded.",
                            )
                        },
                    )?,
                ),
                evidence: PreviewEvidence {
                    external_workload_id: Some(workload_id.to_owned()),
                    external_workload_evidence_digest: evidence_digest,
                    external_workload_healthy: Some(healthy),
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
                    active_inference_available: active_available,
                    engine_transitioning: manager.is_transitioning(),
                    active_engine: active,
                    cluster_membership_available: cluster_available,
                    cluster_membership_source: cluster_available
                        .then(|| "runtime_cache".to_owned()),
                    cluster,
                },
            },
            consequences: PreviewConsequences {
                model_to_stop: None,
                profile_to_stop: None,
                route_withdrawal: false,
                service_interruption: "none".into(),
                files_removed: Vec::new(),
                reinstall_required: false,
                alternative_profiles: None,
            },
            blockers,
            warnings: vec![
                PreviewMessage::warning(
                    "CONTROL_TRANSFER",
                    "This review transfers lifecycle control. A later approved unload or switch, or a memory-safety emergency, may stop this exact container. SparkPilot never deletes it.",
                ),
                PreviewMessage::warning(
                    "NO_DOWNTIME",
                    "Adoption keeps the running container and its current loopback endpoint in place.",
                ),
                PreviewMessage::warning(
                    "FILES_RETAINED",
                    "The model snapshot, container and mounted files are retained.",
                ),
                PreviewMessage::warning(
                    "ROLLBACK_LIMIT",
                    "Relinquishing later removes only SparkPilot's ownership record. It does not restore configuration changed outside SparkPilot after adoption.",
                ),
            ],
        },
        recipe,
        host_port,
    ))
}

pub(super) fn mismatch_blocker(code: &str) -> PreviewMessage {
    let public_code = match code {
        "IMAGE_DIGEST_MISMATCH"
        | "ARGUMENTS_MISMATCH"
        | "MOUNTS_MISMATCH"
        | "NETWORK_POLICY_MISMATCH"
        | "CONTAINER_SECURITY_MISMATCH"
        | "CONFIGURATION_MISMATCH"
        | "WORKLOAD_NOT_RUNNING"
        | "WORKLOAD_ID_MISMATCH"
        | "ENTRYPOINT_MISMATCH" => code,
        _ => "WORKLOAD_CONFIGURATION_MISMATCH",
    };
    let explanation = match code {
        "IMAGE_DIGEST_MISMATCH" => {
            "The container does not use the recipe's immutable image digest."
        }
        "ARGUMENTS_MISMATCH" => {
            "The engine arguments, model revision or served alias do not exactly match the signed recipe and profile."
        }
        "MOUNTS_MISMATCH" => {
            "The model mount or temporary filesystem does not exactly match the lifecycle policy."
        }
        "NETWORK_POLICY_MISMATCH" => {
            "The loopback publication, port or container network does not exactly match the lifecycle policy."
        }
        "CONTAINER_SECURITY_MISMATCH" => {
            "The container security settings do not exactly match the lifecycle policy."
        }
        "CONFIGURATION_MISMATCH" => {
            "The container has environment configuration beyond the immutable image defaults."
        }
        "WORKLOAD_NOT_RUNNING" => "The external container is not running.",
        _ => "The container identity or configuration does not exactly match the signed recipe.",
    };
    PreviewMessage::blocker(
        public_code,
        explanation,
        "Keep this workload externally managed or deploy the signed recipe through SparkPilot.",
    )
}

pub async fn preview_adoption(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Path(workload_id): Path<String>,
    idempotency: IdempotencyRequest,
    Json(request): Json<AdoptionPreviewRequest>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    require_administrator(&principal)?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| error(StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL", "no database"))?;
    let (draft, _, _) =
        adoption_draft(&state, &workload_id, &request.model_id, &request.profile_id).await?;
    let preview = state.previews.issue(&draft).map_err(|_| {
        error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL",
            "The adoption review could not be issued.",
        )
    })?;
    crate::audit::append_committed(
        database,
        state.clock.as_ref(),
        &crate::audit::AuditDraft {
            actor_device_id: Some(principal.device_id),
            actor_role: Some(&principal.role),
            source_route: "/api/v1/workloads/{workload_id}/adoption/preview",
            action: "workload.adopt.preview",
            resource: Some(&workload_id),
            result: "accepted",
            operation_id: None,
            request_id: idempotency.request_id,
            details: &json!({
                "model_id": request.model_id,
                "profile_id": request.profile_id,
                "preview_digest": preview.get("preview_digest"),
            }),
        },
    )
    .map_err(crate::audit::unavailable_envelope)?;
    Ok(Json(preview))
}
