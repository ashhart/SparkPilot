use super::*;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PreviewValidationError {
    Required,
    Invalid,
    NotFound,
    Expired,
    ActionMismatch,
    AlreadyAccepted,
    Stale,
    Blocked(String),
}

impl PreviewValidationError {
    pub fn code(&self) -> &str {
        match self {
            Self::Required => "PREVIEW_REQUIRED",
            Self::Invalid => "PREVIEW_INVALID",
            Self::NotFound => "PREVIEW_NOT_FOUND",
            Self::Expired => "PREVIEW_EXPIRED",
            Self::ActionMismatch => "PREVIEW_ACTION_MISMATCH",
            Self::AlreadyAccepted => "PREVIEW_ALREADY_ACCEPTED",
            Self::Stale => "PREVIEW_STALE",
            Self::Blocked(code) => code,
        }
    }

    pub fn envelope(&self) -> (StatusCode, Json<Value>) {
        let (status, code, message) = match self {
            Self::Required => (
                StatusCode::PRECONDITION_REQUIRED,
                "PREVIEW_REQUIRED",
                "apply requires an accepted preview digest",
            ),
            Self::Invalid => (
                StatusCode::UNPROCESSABLE_ENTITY,
                "PREVIEW_INVALID",
                "accepted preview digest must be 64 lowercase hexadecimal characters",
            ),
            Self::NotFound => (
                StatusCode::PRECONDITION_FAILED,
                "PREVIEW_NOT_FOUND",
                "preview evidence is no longer available; request a new preview",
            ),
            Self::Expired => (
                StatusCode::PRECONDITION_FAILED,
                "PREVIEW_EXPIRED",
                "preview expired; request a new preview",
            ),
            Self::ActionMismatch => (
                StatusCode::CONFLICT,
                "PREVIEW_ACTION_MISMATCH",
                "preview was issued for a different action or target",
            ),
            Self::AlreadyAccepted => (
                StatusCode::CONFLICT,
                "PREVIEW_ALREADY_ACCEPTED",
                "preview was already accepted by a different apply request",
            ),
            Self::Stale => (
                StatusCode::CONFLICT,
                "PREVIEW_STALE",
                "runtime evidence changed; request a new preview",
            ),
            Self::Blocked(code) => (
                StatusCode::CONFLICT,
                code.as_str(),
                "the accepted preview contains a blocker",
            ),
        };
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
}

pub fn action_key(action: &str, parameters: Value) -> String {
    sha256_hex(
        &serde_json::to_vec(&json!({ "action": action, "parameters": parameters }))
            .expect("action keys contain serializable JSON"),
    )
}

pub fn target_and_cluster(
    state: &AppState,
) -> Result<(PreviewTarget, bool, Option<PreviewClusterEvidence>), String> {
    let Some(cluster) = &state.cluster else {
        return Ok((
            PreviewTarget {
                node_id: state.identity.node_id(),
                cluster_id: None,
            },
            false,
            None,
        ));
    };
    let status = cluster.status().map_err(|error| error.to_string())?;
    let target = PreviewTarget {
        node_id: state.identity.node_id(),
        cluster_id: status.id.clone(),
    };
    let evidence = PreviewClusterEvidence {
        cluster_id: status.id,
        state: status.state,
        members: status
            .members
            .into_iter()
            .map(|member| PreviewClusterMember {
                node_id: member.node_id,
                role: member.role,
                reachable: member.reachable,
                reachability_source: "runtime_cache".to_owned(),
            })
            .collect(),
    };
    Ok((target, true, Some(evidence)))
}

pub fn active_engine(
    state: &AppState,
) -> Result<
    (
        bool,
        Option<PreviewActiveEngine>,
        Option<PreviewRecipeIdentity>,
    ),
    serde_json::Error,
> {
    let Some(manager) = &state.engine.manager else {
        return Ok((false, None, None));
    };
    let Some(view) = manager.view() else {
        return Ok((true, None, None));
    };
    let recipe = PreviewRecipeIdentity::from_recipe(&view.recipe, Some(&view.profile_id))?;
    let active = PreviewActiveEngine {
        state: view.state.inference_value().to_owned(),
        model_id: view.model_id,
        profile_id: view.profile_id,
        recipe_revision: recipe.recipe_revision.clone(),
        source_revision: recipe.source_revision.clone(),
        recipe_digest: recipe.recipe_digest.clone(),
        signature_key_id: recipe.signature_key_id.clone(),
        active_requests: view.active_requests,
        reserved_memory_bytes: view.reserved_memory_bytes,
    };
    Ok((true, Some(active), Some(recipe)))
}

/// Unknown GPU registry evidence is inconclusive; block only proven NVIDIA-runtime absence or unavailable container prerequisites.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GpuRuntimeEvidence {
    Present,
    Absent,
    Unknown,
}

/// Select preflight rules by backend kind so mock availability cannot incorrectly block in-process inference.
pub fn container_preflight_blockers(
    backend_kind: &str,
    available: bool,
    detail: Option<&str>,
    gpu_runtime: GpuRuntimeEvidence,
) -> Vec<PreviewMessage> {
    match backend_kind {
        // The mock backend serves inference directly and requires no host container runtime.
        "mock" => Vec::new(),
        "docker" => {
            let mut blockers = Vec::new();
            if !available {
                blockers.push(PreviewMessage::blocker(
                    "CONTAINER_RUNTIME_UNAVAILABLE",
                    detail.unwrap_or(
                        "This Spark's container runtime is not responding, so the inference                          engine cannot be prepared or started.",
                    ),
                    "Start the container runtime on this Spark, then request a new preview.",
                ));
                // Report runtime unavailability alone because GPU registration cannot be evaluated while it is down.
                return blockers;
            }
            if gpu_runtime == GpuRuntimeEvidence::Absent {
                blockers.push(PreviewMessage::blocker(
                    "GPU_RUNTIME_UNAVAILABLE",
                    "This Spark's container runtime does not report an NVIDIA GPU runtime, so                      the engine would start without the accelerator it requires.",
                    "Install the NVIDIA container runtime on this Spark, then request a new                      preview.",
                ));
            }
            blockers
        }
        // An absent or unrecognized engine backend cannot satisfy container prerequisites.
        _ => vec![PreviewMessage::blocker(
            "CONTAINER_RUNTIME_UNAVAILABLE",
            "This Spark has no configured container runtime for the inference engine.",
            "Install a Spark Runtime with container support, then request a new preview.",
        )],
    }
}
