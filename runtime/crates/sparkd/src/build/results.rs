use super::*;

pub(super) struct Results<'a> {
    pub(super) db: &'a Mutex<rusqlite::Connection>,
    pub(super) jobs: &'a JobService,
    pub(super) identity: &'a NodeIdentity,
    pub(super) events: &'a EventBus,
    pub(super) work_dir: &'a Path,
    pub(super) claims: claims::Claims<'a>,
}

impl Results<'_> {
    pub fn record_result(
        &self,
        build_id: &Uuid,
        worker_id: &Uuid,
        claim_token: &str,
        device_public_key_spki: &[u8],
        result: &SignedBuildResult,
    ) -> Result<store::BuildRow, &'static str> {
        result.verify(device_public_key_spki)?;
        let conn = self.db.lock();
        let current = store::build_row(&conn, build_id)
            .map_err(|_| "BUILD_NOT_FOUND")?
            .ok_or("BUILD_NOT_FOUND")?;
        if matches!(
            current.status.as_str(),
            "completed" | "failed" | "cancelled"
        ) {
            let repeated = serde_json::to_string(result).map_err(|_| "BUILD_RESULT_INVALID")?;
            return if current.worker_id == Some(*worker_id) && current.result_json == repeated {
                Ok(current)
            } else {
                Err("BUILD_RESULT_ALREADY_RECORDED")
            };
        }
        let build = self
            .claims
            .verify_claim_locked(&conn, build_id, worker_id, claim_token)?;
        let evidence = &result.evidence;
        if evidence.build_id != *build_id
            || evidence.worker_id != *worker_id
            || evidence.claim_generation != build.claim_generation
            || evidence.project_id != build.project_id
            || evidence.commit != build.commit_sha
            || evidence.source_sha256 != build.source_sha256
            || build.recipe_sha256.as_deref() != Some(evidence.recipe_sha256.as_str())
        {
            return Err("BUILD_RESULT_BINDING_MISMATCH");
        }
        validate_result_times(evidence, self.jobs.now())?;
        let operation = self
            .jobs
            .get(&conn, build.operation_id)
            .map_err(|_| "BUILD_OPERATION_INVALID")?
            .ok_or("BUILD_OPERATION_INVALID")?;
        let cancellation = operation.state == "cancelling";
        let uploaded = store::build_artifacts(&conn, build_id, build.claim_generation)
            .map_err(|_| "BUILD_ARTIFACT_STORE_FAILED")?;
        if cancellation {
            if !evidence.artifacts.is_empty() {
                return Err("BUILD_RESULT_INVALID");
            }
        } else if !artifacts_match(&uploaded, &evidence.artifacts) {
            return Err("BUILD_RESULT_HASH_MISMATCH");
        }
        if cancellation && evidence.exit_state != "cancelled" {
            return Err("BUILD_CANCELLATION_PENDING");
        }
        if !cancellation && evidence.exit_state == "cancelled" {
            return Err("BUILD_RESULT_INVALID");
        }
        let status = match evidence.exit_state.as_str() {
            "succeeded" => "completed",
            "failed" => "failed",
            "cancelled" => "cancelled",
            _ => return Err("BUILD_RESULT_INVALID"),
        };
        let result_json = serde_json::to_string(result).map_err(|_| "BUILD_RESULT_INVALID")?;
        let completed_at = self.jobs.now_rfc3339();
        let transaction = conn
            .unchecked_transaction()
            .map_err(|_| "BUILD_RESULT_STORE_FAILED")?;
        let changed = store::finish_build_claim(
            &transaction,
            build_id,
            worker_id,
            build
                .claim_token_hash
                .as_deref()
                .ok_or("BUILD_CLAIM_INVALID")?,
            build.claim_generation,
            build
                .recipe_sha256
                .as_deref()
                .ok_or("BUILD_RECIPE_INVALID")?,
            status,
            &result_json,
            &completed_at,
        )
        .map_err(|_| "BUILD_RESULT_STORE_FAILED")?;
        if !changed {
            return Err("BUILD_CLAIM_LOST");
        }
        let remaining = store::active_build_count_for_worker(&transaction, worker_id)
            .map_err(|_| "BUILD_RESULT_STORE_FAILED")?;
        if remaining == 0 {
            store::update_build_worker_state_at(&transaction, worker_id, "online", &completed_at)
                .map_err(|_| "BUILD_RESULT_STORE_FAILED")?;
        }
        if status == "cancelled" {
            store::delete_build_artifacts(&transaction, build_id, build.claim_generation)
                .map_err(|_| "BUILD_RESULT_STORE_FAILED")?;
            let generation_dir = self
                .work_dir
                .join("builds")
                .join(build.id.to_string())
                .join(build.claim_generation.to_string());
            if generation_dir.exists() {
                std::fs::remove_dir_all(generation_dir).map_err(|_| "BUILD_RESULT_STORE_FAILED")?;
            }
            self.jobs
                .cancelled(&transaction, build.operation_id, "OPERATION_CANCELLED")
                .map_err(|_| "BUILD_RESULT_STORE_FAILED")?;
        } else {
            self.jobs
                .succeed(
                    &transaction,
                    build.operation_id,
                    &json!({ "build_id": build_id }),
                )
                .map_err(|_| "BUILD_RESULT_STORE_FAILED")?;
        }
        transaction
            .commit()
            .map_err(|_| "BUILD_RESULT_STORE_FAILED")?;
        if serde_json::from_str::<Vec<String>>(&build.actions_json)
            .is_ok_and(|actions| actions.iter().any(|action| action == "test"))
        {
            self.events.emit_scoped(
                Some(&conn),
                &self.identity.node_id().to_string(),
                Some(build.operation_id),
                "build.test.completed",
                if evidence.test_failures.is_empty() {
                    "info"
                } else {
                    "warning"
                },
                json!({
                    "build_id": build_id,
                    "exit_state": evidence.exit_state,
                    "failure_count": evidence.test_failures.len(),
                }),
                crate::events::Visibility::project(build.project_id),
            );
        }
        self.events.emit_scoped(
            Some(&conn),
            &self.identity.node_id().to_string(),
            Some(build.operation_id),
            match status {
                "completed" => "build.completed",
                "cancelled" => "build.cancelled",
                _ => "build.failed",
            },
            if status == "completed" {
                "info"
            } else {
                "error"
            },
            json!({ "build_id": build_id, "exit_state": evidence.exit_state }),
            crate::events::Visibility::project(build.project_id),
        );
        store::build_row(&conn, build_id)
            .map_err(|_| "BUILD_RESULT_STORE_FAILED")?
            .ok_or("BUILD_NOT_FOUND")
    }
}
