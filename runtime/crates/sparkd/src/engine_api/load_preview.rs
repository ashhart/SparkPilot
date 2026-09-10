use super::*;

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LoadTargetBody {
    #[serde(default)]
    pub node_id: Option<String>,
    #[serde(default)]
    pub cluster_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LoadModelBody {
    pub model_id: String,
    pub profile_id: String,
    #[serde(default)]
    pub replace_active: bool,
    #[serde(default)]
    pub target: Option<LoadTargetBody>,
    #[serde(default)]
    pub accepted_preview_digest: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LoadModelPreviewBody {
    pub model_id: String,
    pub profile_id: String,
    #[serde(default)]
    pub replace_active: bool,
    #[serde(default)]
    pub target: Option<LoadTargetBody>,
}

pub(super) fn pressure_name(pressure: PressureState) -> &'static str {
    match pressure {
        PressureState::Normal => "normal",
        PressureState::Warning => "warning",
        PressureState::Draining => "draining",
        PressureState::Critical => "critical",
        PressureState::Emergency => "emergency",
        PressureState::Recovering => "recovering",
    }
}

pub(super) fn admission_name(decision: AdmissionDecision) -> &'static str {
    match decision {
        AdmissionDecision::Allow { .. } => "allow",
        AdmissionDecision::DenyInsufficientMemory => "deny_insufficient_memory",
        AdmissionDecision::DenyPressureActive => "deny_pressure_active",
        AdmissionDecision::DenyProfileUnsafe => "deny_profile_unsafe",
    }
}

/// Permit signed local recovery only for retained degraded membership after verified distributed stop; READY or ambiguous cluster state remains blocked.
pub(super) fn degraded_single_node_recovery_allowed(
    connection: &rusqlite::Connection,
    local_node_id: uuid::Uuid,
    target_cluster_id: Option<&str>,
    requested_target: Option<&LoadTargetBody>,
) -> rusqlite::Result<bool> {
    let (Some(cluster_id), Some(requested)) = (target_cluster_id, requested_target) else {
        return Ok(false);
    };
    let local_node_id = local_node_id.to_string();
    if requested.node_id.as_deref() != Some(local_node_id.as_str())
        || requested.cluster_id.as_deref() != Some(cluster_id)
    {
        return Ok(false);
    }

    connection.query_row(
        "SELECT EXISTS(
           SELECT 1
           FROM cluster_state state
           JOIN cluster_transactions transaction_row
             ON transaction_row.cluster_id=state.id
            AND transaction_row.state='ready'
           JOIN cluster_members local_member
             ON local_member.cluster_id=state.id
            AND local_member.node_id=?2
            AND local_member.reachable=1
           WHERE state.id=?1
             AND state.state='degraded'
             AND (SELECT COUNT(*) FROM cluster_members member
                  WHERE member.cluster_id=state.id)=2
             AND EXISTS(
                   SELECT 1 FROM cluster_members peer
                   WHERE peer.cluster_id=state.id
                     AND peer.node_id!=?2
                     AND peer.reachable=0
                 )
             AND EXISTS(
                   SELECT 1 FROM cluster_launches launch
                   WHERE launch.cluster_id=state.id
                     AND launch.state='stopped'
                     AND launch.failure_code IN (
                       'WORKER_LOST',
                       'COORDINATOR_LOST_PROMOTION_REQUIRED'
                     )
                 )
             AND NOT EXISTS(
                   SELECT 1 FROM cluster_launches active_launch
                   WHERE active_launch.cluster_id=state.id
                     AND active_launch.state IN (
                       'preparing','running','degraded','stopping'
                     )
                 )
         )",
        rusqlite::params![cluster_id, local_node_id],
        |row| row.get::<_, i64>(0).map(|allowed| allowed == 1),
    )
}

pub(crate) fn load_preview_draft(
    state: &AppState,
    model_id: &str,
    profile_id: &str,
    replace_active: bool,
    requested_target: Option<&LoadTargetBody>,
    container: Option<&crate::engine::ContainerRuntimeReport>,
    external_inference: crate::workload_api::ExternalInferenceGuard,
) -> Result<(PreviewDraft, spark_models::ModelRecipe), (StatusCode, Json<Value>)> {
    if model_id.is_empty() || profile_id.is_empty() {
        return Err(err(
            "MODEL_RECIPE_INVALID",
            "model_id and profile_id are required",
            StatusCode::UNPROCESSABLE_ENTITY,
        ));
    }
    let inventory = state
        .models
        .as_ref()
        .ok_or_else(|| crate::models::internal_envelope("inventory unavailable"))?
        .snapshot();
    let recipe = inventory.recipe(model_id).cloned().ok_or_else(|| {
        err(
            "MODEL_NOT_INSTALLED",
            "model not found",
            StatusCode::NOT_FOUND,
        )
    })?;
    let profile = recipe
        .profiles
        .iter()
        .find(|profile| profile.id == profile_id)
        .ok_or_else(|| {
            err(
                "MODEL_RECIPE_INVALID",
                format!("profile {profile_id} is not in the signed recipe"),
                StatusCode::UNPROCESSABLE_ENTITY,
            )
        })?;
    let manager = state
        .engine
        .manager
        .as_ref()
        .ok_or_else(|| crate::models::internal_envelope("engine unavailable"))?;
    let db = state
        .database
        .as_ref()
        .ok_or_else(|| crate::models::internal_envelope("no database"))?;
    let row = crate::store::model_row(&db.lock(), recipe.id())
        .map_err(|error| crate::models::internal_envelope(&error.to_string()))?
        .ok_or_else(|| crate::models::internal_envelope("model row missing"))?;
    let admission = manager
        .admission_evidence(&recipe, profile, replace_active)
        .map_err(|error| error.envelope())?;
    let (target, cluster_available, cluster) =
        target_and_cluster(state).map_err(|error| crate::models::internal_envelope(&error))?;
    let (active_available, active, _) = active_engine(state)
        .map_err(|error| crate::models::internal_envelope(&error.to_string()))?;
    let mut blockers = Vec::new();
    if row.install_state != "installed" {
        blockers.push(PreviewMessage::blocker(
            "MODEL_NOT_INSTALLED",
            "The selected model revision is not installed on this target.",
            "Install the model and request a new preview.",
        ));
    }
    // §32.4: name the profiles the current budget admits so a refusal offers a real choice.
    let mut alternative_profiles = None;
    match admission.decision {
        AdmissionDecision::Allow { .. } => {}
        AdmissionDecision::DenyInsufficientMemory => {
            alternative_profiles = Some(crate::preview::PreviewAlternativeProfile::admissible(
                &recipe,
                profile_id,
                |candidate| {
                    manager
                        .admission_evidence(&recipe, candidate, replace_active)
                        .is_ok_and(|evidence| {
                            matches!(evidence.decision, AdmissionDecision::Allow { .. })
                        })
                },
            ));
            blockers.push(PreviewMessage::blocker(
                "MODEL_INSUFFICIENT_MEMORY",
                "The profile does not fit while preserving the required system reserve.",
                "Stop the active model, choose a smaller profile, or choose another target.",
            ));
        }
        AdmissionDecision::DenyPressureActive => blockers.push(PreviewMessage::blocker(
            "MEMORY_PRESSURE_ACTIVE",
            "The memory guard is not in its normal state.",
            "Wait for memory pressure to clear and request a new preview.",
        )),
        AdmissionDecision::DenyProfileUnsafe => blockers.push(PreviewMessage::blocker(
            "MODEL_PROFILE_UNSAFE",
            "The profile was marked unsafe after a memory failure.",
            "Choose a safe profile or explicitly re-enable this profile before retrying.",
        )),
    }
    let single_node_recovery = degraded_single_node_recovery_allowed(
        &db.lock(),
        state.identity.node_id(),
        target.cluster_id.as_deref(),
        requested_target,
    )
    .map_err(|error| crate::models::internal_envelope(&error.to_string()))?;
    // Treat cluster loads as distributed unless exact signed recovery evidence proves peer loss and distributed stop.
    let cluster_requested = requested_target
        .and_then(|requested| requested.cluster_id.as_ref())
        .is_some();
    if (cluster_requested || target.cluster_id.is_some()) && !single_node_recovery {
        blockers.push(PreviewMessage::blocker(
            "CLUSTER_INFERENCE_UNAVAILABLE",
            "Distributed inference is unavailable because this runtime has no qualified cluster launch backend.",
            "Use a standalone Spark, or wait until this runtime reports a qualified cluster inference capability.",
        ));
    }
    if let Some(requested) = requested_target
        && (requested
            .node_id
            .as_deref()
            .is_some_and(|node_id| node_id != target.node_id.to_string())
            || requested.cluster_id != target.cluster_id)
    {
        blockers.push(PreviewMessage::blocker(
            "TARGET_IDENTITY_MISMATCH",
            "The requested node or cluster is not this runtime target.",
            "Choose the current target identity and request a new preview.",
        ));
    }
    if active.is_some() && !replace_active {
        blockers.push(PreviewMessage::blocker(
            "ENGINE_ACTIVE",
            "Another engine is active and replacement was not confirmed.",
            "Request a replacement preview with replace_active set to true.",
        ));
    }
    if !active_available {
        blockers.push(PreviewMessage::blocker(
            "ACTIVE_INFERENCE_EVIDENCE_UNAVAILABLE",
            "The runtime cannot prove the current inference state.",
            "Restore the engine service and request a new preview.",
        ));
    }
    match external_inference {
        crate::workload_api::ExternalInferenceGuard::Active => {
            blockers.push(PreviewMessage::blocker(
                "EXTERNAL_ENGINE_ACTIVE",
                "An externally managed inference engine is already active on this Spark.",
                "Keep using the external endpoint. SparkPilot will not replace it until a separate takeover flow is available.",
            ));
        }
        crate::workload_api::ExternalInferenceGuard::Unknown => {
            blockers.push(PreviewMessage::blocker(
                "EXTERNAL_ENGINE_STATE_UNKNOWN",
                "SparkPilot could not prove that starting an engine would leave external workloads untouched.",
                "Restore the container workload inventory and request a new preview.",
            ));
        }
        crate::workload_api::ExternalInferenceGuard::NotChecked
        | crate::workload_api::ExternalInferenceGuard::Clear => {}
    }
    let engine_transitioning = manager.is_transitioning();
    if engine_transitioning {
        blockers.push(PreviewMessage::blocker(
            "ENGINE_NOT_READY",
            "Another engine transition is still in progress.",
            "Wait for the current operation to finish and request a new preview.",
        ));
    }

    // Bind runtime prerequisites into preview blockers so apply cannot bypass failed preflight before pulling or launching an image.
    if let Some(report) = container {
        blockers.extend(crate::preview::container_preflight_blockers(
            report.backend_kind,
            report.available,
            report.detail.as_deref(),
            // Keep absent runtime-registry evidence unknown rather than treating it as a negative GPU finding.
            match report.gpu_runtime {
                Some(true) => crate::preview::GpuRuntimeEvidence::Present,
                Some(false) => crate::preview::GpuRuntimeEvidence::Absent,
                None => crate::preview::GpuRuntimeEvidence::Unknown,
            },
        ));
    }

    let mut consequences = active
        .as_ref()
        .map(|active| PreviewConsequences {
            model_to_stop: Some(active.model_id.clone()),
            profile_to_stop: Some(active.profile_id.clone()),
            route_withdrawal: true,
            service_interruption: "until_model_ready".to_owned(),
            files_removed: Vec::new(),
            reinstall_required: false,
            alternative_profiles: None,
        })
        .unwrap_or_default();
    consequences.alternative_profiles = alternative_profiles;
    let warnings = active
        .as_ref()
        .map(|active| {
            let mut messages = vec![PreviewMessage::warning(
                "MODEL_ROUTE_INTERRUPTION",
                "The active inference route will be withdrawn until the selected model is ready.",
            )];
            if active.active_requests > 0 {
                messages.push(PreviewMessage::warning(
                    "ACTIVE_REQUESTS_WILL_DRAIN",
                    "Active inference requests will drain before the engine stops.",
                ));
            }
            messages
        })
        .unwrap_or_default();
    let system = state.telemetry.system();
    let binding = PreviewBinding {
        target,
        recipe: Some(
            PreviewRecipeIdentity::from_recipe(&recipe, Some(profile_id))
                .map_err(|error| crate::models::internal_envelope(&error.to_string()))?,
        ),
        evidence: PreviewEvidence {
            external_workload_id: None,
            external_workload_evidence_digest: None,
            external_workload_healthy: None,
            remote: None,
            install_state: Some(row.install_state),
            installed_bytes: row.total_bytes.and_then(|bytes| u64::try_from(bytes).ok()),
            removable_bytes: None,
            download_bytes: None,
            locally_reusable_bytes: None,
            required_disk_bytes: None,
            disk_free_bytes: Some(system.disk_free_bytes),
            expected_disk_free_after_bytes: None,
            required_memory_bytes: Some(admission.required_memory_bytes),
            available_memory_bytes: Some(admission.available_memory_bytes),
            system_reserve_bytes: Some(admission.system_reserve_bytes),
            expected_memory_headroom_bytes: Some(admission.expected_headroom_bytes),
            launch_memory: crate::preview::PreviewLaunchMemory::from_admission(&admission),
            memory_pressure: Some(pressure_name(admission.pressure).to_owned()),
            memory_admission: Some(admission_name(admission.decision).to_owned()),
            profile_failure_code: None,
            active_inference_available: active_available,
            engine_transitioning,
            active_engine: active.clone(),
            cluster_membership_available: cluster_available,
            cluster_membership_source: cluster_available.then(|| "runtime_cache".to_owned()),
            cluster,
        },
    };
    let action = if active.is_some() { "replace" } else { "load" };
    Ok((
        PreviewDraft {
            action,
            action_key: action_key(
                "load",
                json!({
                    "model_id": model_id,
                    "profile_id": profile_id,
                    "replace_active": replace_active,
                    "target": requested_target.map(|target| json!({
                        "node_id": target.node_id,
                        "cluster_id": target.cluster_id,
                    })),
                }),
            ),
            binding,
            consequences,
            blockers,
            warnings,
        },
        recipe,
    ))
}
