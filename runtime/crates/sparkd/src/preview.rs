//! Apply retained server previews only after live rebinding; unknown, expired, changed or restart-lost evidence fails closed.

use std::collections::HashMap;

use std::sync::Arc;

use axum::Json;

use axum::http::StatusCode;

use parking_lot::Mutex;

use serde::Serialize;

use serde_json::{Value, json};

use time::OffsetDateTime;

use crate::clock::UtcClock;

use crate::crypto::sha256_hex;

use crate::state::AppState;

const PREVIEW_LIFETIME: time::Duration = time::Duration::minutes(5);

const MAX_LIVE_PREVIEWS: usize = 1024;

#[derive(Debug, Clone)]
struct PreviewRecord {
    action_key: String,
    decision_digest: String,
    expires_at: OffsetDateTime,
    blockers: Vec<String>,
    accepted_by: Option<String>,
}

#[derive(Clone)]
pub struct PreviewService {
    clock: Arc<dyn UtcClock>,
    records: Arc<Mutex<HashMap<String, PreviewRecord>>>,
}

impl PreviewService {
    pub fn new(clock: Arc<dyn UtcClock>) -> Self {
        Self {
            clock,
            records: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn issue(&self, draft: &PreviewDraft) -> Result<Value, serde_json::Error> {
        let now = self.clock.now();
        let expires_at = now + PREVIEW_LIFETIME;
        let observed_at = self.clock.now_rfc3339();
        let unsigned = UnsignedPreview {
            action: draft.action,
            target: &draft.binding.target,
            recipe: &draft.binding.recipe,
            evidence: &draft.binding.evidence,
            evidence_timestamps: EvidenceTimestamps {
                system_observed_at: observed_at.clone(),
                active_inference_observed_at: draft
                    .binding
                    .evidence
                    .active_inference_available
                    .then(|| observed_at.clone()),
                recipe_authority_observed_at: draft
                    .binding
                    .recipe
                    .as_ref()
                    .map(|_| observed_at.clone()),
                cluster_membership_observed_at: draft
                    .binding
                    .evidence
                    .cluster_membership_available
                    .then(|| observed_at.clone()),
            },
            consequences: &draft.consequences,
            blockers: &draft.blockers,
            warnings: &draft.warnings,
            issued_at: observed_at,
            expires_at: format_time(expires_at),
        };
        let preview_digest = sha256_hex(&serde_json::to_vec(&unsigned)?);
        let response = serde_json::to_value(ActionPreview {
            preview_digest: preview_digest.clone(),
            unsigned,
        })?;
        let record = PreviewRecord {
            action_key: draft.action_key.clone(),
            decision_digest: decision_digest(draft)?,
            expires_at,
            blockers: draft
                .blockers
                .iter()
                .map(|message| message.code.clone())
                .collect(),
            accepted_by: None,
        };
        let mut records = self.records.lock();
        records.retain(|_, record| record.expires_at > now);
        if records.len() >= MAX_LIVE_PREVIEWS
            && let Some(oldest) = records
                .iter()
                .min_by_key(|(_, record)| record.expires_at)
                .map(|(digest, _)| digest.clone())
        {
            records.remove(&oldest);
        }
        records.insert(preview_digest, record);
        Ok(response)
    }

    pub fn validate(
        &self,
        accepted_digest: Option<&str>,
        current: &PreviewDraft,
        acceptance_key: &str,
    ) -> Result<(), PreviewValidationError> {
        let digest = accepted_digest.ok_or(PreviewValidationError::Required)?;
        if digest.len() != 64
            || !digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
        {
            return Err(PreviewValidationError::Invalid);
        }
        let now = self.clock.now();
        let mut records = self.records.lock();
        let Some(record) = records.get(digest).cloned() else {
            return Err(PreviewValidationError::NotFound);
        };
        if record.expires_at <= now {
            records.remove(digest);
            return Err(PreviewValidationError::Expired);
        }
        if record.action_key != current.action_key {
            return Err(PreviewValidationError::ActionMismatch);
        }
        if record
            .accepted_by
            .as_deref()
            .is_some_and(|accepted_by| accepted_by != acceptance_key)
        {
            return Err(PreviewValidationError::AlreadyAccepted);
        }
        let current_digest = decision_digest(current).map_err(|_| PreviewValidationError::Stale)?;
        if current_digest != record.decision_digest {
            return Err(PreviewValidationError::Stale);
        }
        if let Some(code) = record.blockers.first() {
            return Err(PreviewValidationError::Blocked(code.clone()));
        }
        if let Some(record) = records.get_mut(digest) {
            record.accepted_by = Some(acceptance_key.to_owned());
        }
        Ok(())
    }
}

fn format_time(value: OffsetDateTime) -> String {
    value
        .to_offset(time::UtcOffset::UTC)
        .format(&time::format_description::well_known::Rfc3339)
        .expect("UTC timestamps always format as RFC3339")
}

#[cfg(test)]
#[path = "preview/tests.rs"]
mod tests;

#[cfg(test)]
#[path = "preview/container_preflight_tests.rs"]
mod container_preflight_tests;

mod evidence;
pub use evidence::{
    ActionPreview, PreviewActiveEngine, PreviewAlternativeProfile, PreviewBinding,
    PreviewClusterEvidence, PreviewClusterMember, PreviewConsequences, PreviewDraft,
    PreviewEvidence, PreviewLaunchMemory, PreviewMessage, PreviewRecipeIdentity,
    PreviewRemoteEvidence, PreviewTarget,
};
use evidence::{EvidenceTimestamps, UnsignedPreview, decision_digest};

mod validation;
pub use validation::{
    GpuRuntimeEvidence, PreviewValidationError, action_key, active_engine,
    container_preflight_blockers, target_and_cluster,
};
