use super::*;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PreviewTarget {
    pub node_id: uuid::Uuid,
    pub cluster_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PreviewRecipeIdentity {
    pub model_id: String,
    pub recipe_revision: String,
    pub source_revision: String,
    pub recipe_digest: String,
    pub signature_key_id: String,
    pub profile_id: Option<String>,
}

impl PreviewRecipeIdentity {
    pub fn from_recipe(
        recipe: &spark_models::ModelRecipe,
        profile_id: Option<&str>,
    ) -> Result<Self, serde_json::Error> {
        Ok(Self {
            model_id: recipe.id().to_owned(),
            recipe_revision: recipe.metadata.revision.clone(),
            source_revision: recipe.source.revision.clone(),
            recipe_digest: sha256_hex(&serde_json::to_vec(recipe)?),
            signature_key_id: recipe.signature.key_id.clone(),
            profile_id: profile_id.map(str::to_owned),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PreviewActiveEngine {
    pub state: String,
    pub model_id: String,
    pub profile_id: String,
    pub recipe_revision: String,
    pub source_revision: String,
    pub recipe_digest: String,
    pub signature_key_id: String,
    pub active_requests: u32,
    pub reserved_memory_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PreviewClusterMember {
    pub node_id: String,
    pub role: String,
    pub reachable: bool,
    pub reachability_source: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PreviewClusterEvidence {
    pub cluster_id: Option<String>,
    pub state: String,
    pub members: Vec<PreviewClusterMember>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PreviewEvidence {
    /// Exact immutable container checked for an ownership transition.
    pub external_workload_id: Option<String>,
    /// SHA-256 of the secret-redacted privileged inspection facts.
    pub external_workload_evidence_digest: Option<String>,
    /// Health established by a bounded loopback probe during review.
    pub external_workload_healthy: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote: Option<PreviewRemoteEvidence>,
    pub install_state: Option<String>,
    pub installed_bytes: Option<u64>,
    pub removable_bytes: Option<u64>,
    pub download_bytes: Option<u64>,
    pub locally_reusable_bytes: Option<u64>,
    pub required_disk_bytes: Option<u64>,
    pub disk_free_bytes: Option<u64>,
    pub expected_disk_free_after_bytes: Option<u64>,
    pub required_memory_bytes: Option<u64>,
    pub available_memory_bytes: Option<u64>,
    pub system_reserve_bytes: Option<u64>,
    pub expected_memory_headroom_bytes: Option<u64>,
    /// ADR-043 breakdown and projections; absent for recipes without per-token arithmetic and for non-load previews.
    #[serde(flatten)]
    pub launch_memory: Option<PreviewLaunchMemory>,
    pub memory_pressure: Option<String>,
    pub memory_admission: Option<String>,
    /// Keep open-ended guard failure diagnostics separate from the closed memory-admission decision vocabulary.
    pub profile_failure_code: Option<String>,
    pub active_inference_available: bool,
    pub engine_transitioning: bool,
    pub active_engine: Option<PreviewActiveEngine>,
    pub cluster_membership_available: bool,
    pub cluster_membership_source: Option<String>,
    pub cluster: Option<PreviewClusterEvidence>,
}

/// What a load reserves, part by part, and what the current budget would admit instead.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct PreviewLaunchMemory {
    pub weight_bytes: u64,
    pub kv_cache_bytes: u64,
    pub state_bytes: u64,
    pub engine_overhead_bytes: u64,
    pub max_context_now: u64,
    pub max_sequences_now: u32,
}

impl PreviewLaunchMemory {
    /// Present only when every part is known; a half-projected breakdown would mislead the owner.
    pub fn from_admission(admission: &crate::engine::AdmissionEvidence) -> Option<Self> {
        let reservation = admission.reservation?;
        Some(Self {
            weight_bytes: reservation.weight_bytes,
            kv_cache_bytes: reservation.kv_cache_bytes,
            state_bytes: reservation.state_bytes,
            engine_overhead_bytes: reservation.engine_overhead_bytes,
            max_context_now: admission.max_context_now?,
            max_sequences_now: admission.max_sequences_now?,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PreviewRemoteEvidence {
    pub mode: String,
    pub health: String,
    pub hostname: Option<String>,
    pub requested_mode_available: bool,
    pub provider: Option<String>,
    /// The helper's Tailscale state when the review would set the overlay up rather than reuse it.
    pub overlay_setup_state: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PreviewConsequences {
    pub model_to_stop: Option<String>,
    pub profile_to_stop: Option<String>,
    pub route_withdrawal: bool,
    pub service_interruption: String,
    pub files_removed: Vec<String>,
    pub reinstall_required: bool,
    /// §32.4: profiles of the same recipe the current budget admits, so a refusal can name one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub alternative_profiles: Option<Vec<PreviewAlternativeProfile>>,
}

/// One named alternative the owner can actually choose, smallest measured peak first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PreviewAlternativeProfile {
    pub profile_id: String,
    pub display_name: String,
    pub max_model_length: u64,
    pub expected_peak_bytes: u64,
}

impl PreviewAlternativeProfile {
    /// §32.4: rank a recipe's other profiles by expected peak and keep the ones `admits` accepts.
    pub fn admissible(
        recipe: &spark_models::ModelRecipe,
        refused_profile_id: &str,
        admits: impl Fn(&spark_models::recipe::Profile) -> bool,
    ) -> Vec<Self> {
        let mut candidates: Vec<Self> = recipe
            .profiles
            .iter()
            .filter(|candidate| candidate.id != refused_profile_id)
            .filter(|candidate| admits(candidate))
            .map(|candidate| Self {
                profile_id: candidate.id.clone(),
                display_name: candidate.display_name.clone(),
                max_model_length: candidate.max_model_length,
                expected_peak_bytes: candidate.expected_peak_bytes,
            })
            .collect();
        // Smallest peak first so the client can offer the safest named alternative without re-sorting.
        candidates.sort_by(|left, right| {
            left.expected_peak_bytes
                .cmp(&right.expected_peak_bytes)
                .then_with(|| left.profile_id.cmp(&right.profile_id))
        });
        // Bound the list to the contract's maxItems so a large recipe cannot inflate a preview.
        candidates.truncate(16);
        candidates
    }
}

impl Default for PreviewConsequences {
    fn default() -> Self {
        Self {
            model_to_stop: None,
            profile_to_stop: None,
            route_withdrawal: false,
            service_interruption: "none".to_owned(),
            files_removed: Vec::new(),
            reinstall_required: false,
            alternative_profiles: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PreviewMessage {
    pub code: String,
    pub owner_explanation: String,
    pub recovery_action: Option<String>,
}

impl PreviewMessage {
    pub fn blocker(code: &str, explanation: &str, recovery: &str) -> Self {
        Self {
            code: code.to_owned(),
            owner_explanation: explanation.to_owned(),
            recovery_action: Some(recovery.to_owned()),
        }
    }

    pub fn warning(code: &str, explanation: &str) -> Self {
        Self {
            code: code.to_owned(),
            owner_explanation: explanation.to_owned(),
            recovery_action: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PreviewBinding {
    pub target: PreviewTarget,
    pub recipe: Option<PreviewRecipeIdentity>,
    pub evidence: PreviewEvidence,
}

#[derive(Debug, Clone)]
pub struct PreviewDraft {
    pub action: &'static str,
    pub action_key: String,
    pub binding: PreviewBinding,
    pub consequences: PreviewConsequences,
    pub blockers: Vec<PreviewMessage>,
    pub warnings: Vec<PreviewMessage>,
}

#[derive(Debug, Serialize)]
pub(super) struct EvidenceTimestamps {
    pub(super) system_observed_at: String,
    pub(super) active_inference_observed_at: Option<String>,
    pub(super) recipe_authority_observed_at: Option<String>,
    pub(super) cluster_membership_observed_at: Option<String>,
}

#[derive(Debug, Serialize)]
pub(super) struct UnsignedPreview<'a> {
    pub(super) action: &'a str,
    pub(super) target: &'a PreviewTarget,
    pub(super) recipe: &'a Option<PreviewRecipeIdentity>,
    pub(super) evidence: &'a PreviewEvidence,
    pub(super) evidence_timestamps: EvidenceTimestamps,
    pub(super) consequences: &'a PreviewConsequences,
    pub(super) blockers: &'a [PreviewMessage],
    pub(super) warnings: &'a [PreviewMessage],
    pub(super) issued_at: String,
    pub(super) expires_at: String,
}

#[derive(Debug, Serialize)]
pub struct ActionPreview<'a> {
    pub preview_digest: String,
    #[serde(flatten)]
    pub(super) unsigned: UnsignedPreview<'a>,
}

/// Digest decision-changing evidence and consequences; retain exact telemetry for display/audit without expiring reviews on harmless drift.
pub(super) fn decision_digest(draft: &PreviewDraft) -> Result<String, serde_json::Error> {
    let evidence = &draft.binding.evidence;
    let disk_admission = evidence.required_disk_bytes.map(|_| {
        if draft
            .blockers
            .iter()
            .any(|message| message.code == "MODEL_INSUFFICIENT_DISK")
        {
            "deny_insufficient_disk"
        } else {
            "allow"
        }
    });
    let active_engine = evidence.active_engine.as_ref().map(|active| {
        json!({
            "state": active.state,
            "model_id": active.model_id,
            "profile_id": active.profile_id,
            "recipe_revision": active.recipe_revision,
            "source_revision": active.source_revision,
            "recipe_digest": active.recipe_digest,
            "signature_key_id": active.signature_key_id,
        })
    });
    let cluster = evidence.cluster.as_ref().map(|cluster| {
        let mut members = cluster.members.clone();
        members.sort_by(|left, right| {
            (&left.node_id, &left.role, left.reachable).cmp(&(
                &right.node_id,
                &right.role,
                right.reachable,
            ))
        });
        json!({
            "cluster_id": cluster.cluster_id,
            "state": cluster.state,
            "members": members,
        })
    });
    let action_evidence = match draft.action {
        "install" => json!({
            "install_state": evidence.install_state,
            "download_bytes": evidence.download_bytes,
            "locally_reusable_bytes": evidence.locally_reusable_bytes,
            "required_disk_bytes": evidence.required_disk_bytes,
            "disk_admission": disk_admission,
        }),
        "load" | "replace" => json!({
            "install_state": evidence.install_state,
            "required_memory_bytes": evidence.required_memory_bytes,
            "system_reserve_bytes": evidence.system_reserve_bytes,
            "memory_admission": evidence.memory_admission,
            "active_inference_available": evidence.active_inference_available,
            "engine_transitioning": evidence.engine_transitioning,
            "active_engine": active_engine,
        }),
        "stop" | "remove" => json!({
            "install_state": evidence.install_state,
            "active_inference_available": evidence.active_inference_available,
            "engine_transitioning": evidence.engine_transitioning,
            "active_engine": active_engine,
        }),
        // Bind profile reenable to the reviewed unsafe state, failure code and measured peak, not just model/profile identity.
        "profile.reenable" => json!({
            "memory_admission": evidence.memory_admission,
            "profile_failure_code": evidence.profile_failure_code,
            "required_memory_bytes": evidence.required_memory_bytes,
        }),
        "workload.adopt" | "workload.relinquish" => json!({
            "external_workload_id": evidence.external_workload_id,
            "external_workload_evidence_digest": evidence.external_workload_evidence_digest,
            "external_workload_healthy": evidence.external_workload_healthy,
            "active_inference_available": evidence.active_inference_available,
            "engine_transitioning": evidence.engine_transitioning,
            "active_engine": active_engine,
        }),
        "remote.enable" | "remote.disable" | "remote.rotate" => json!({
            "remote": evidence.remote,
        }),
        _ => Value::Null,
    };
    let decision = json!({
        "action": draft.action,
        "target": draft.binding.target,
        "recipe": draft.binding.recipe,
        "action_evidence": action_evidence,
        "cluster_membership_available": evidence.cluster_membership_available,
        "cluster_membership_source": evidence.cluster_membership_source,
        "cluster": cluster,
        "consequences": draft.consequences,
        "blocker_codes": draft.blockers.iter().map(|message| &message.code).collect::<Vec<_>>(),
    });
    serde_json::to_vec(&decision).map(|bytes| sha256_hex(&bytes))
}
