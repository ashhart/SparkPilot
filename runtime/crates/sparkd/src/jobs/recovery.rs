use super::*;

pub(super) struct Recovery<'a> {
    pub(super) clock: &'a Arc<dyn UtcClock>,
    pub(super) cancellations: &'a Mutex<CancellationRegistry>,
    /// Work this process already resumed is left alone, so recovery is safe to repeat.
    pub(super) daemon_id: &'a str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecoveryAction {
    ResumeModelInstall {
        operation_id: Uuid,
        model_id: String,
        provider_credential_id: Option<Uuid>,
    },
    ReconcileRuntimeUpdate {
        operation_id: Uuid,
        release_id: String,
        system_packages: bool,
        firmware: bool,
    },
    ResumeCatalogueRefresh {
        operation_id: Uuid,
        candidate_json: String,
    },
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RecoveryReport {
    pub cancelled: usize,
    pub failed: usize,
    pub resumable: usize,
    pub succeeded: usize,
}

#[derive(Debug)]
struct RecoveryCandidate {
    id: Uuid,
    kind: String,
    state: String,
    stage: String,
    resource_id: Option<String>,
    input_json: String,
    lease_expires_at: Option<String>,
    lease_owner: Option<String>,
}

impl Recovery<'_> {
    fn now_rfc3339(&self) -> String {
        self.clock.now_rfc3339()
    }

    /// Startup recovery must never replay work still owned by this daemon.
    fn is_mine_and_live(&self, candidate: &RecoveryCandidate, _now: time::OffsetDateTime) -> bool {
        candidate.lease_owner.as_deref().is_some_and(|owner| {
            owner
                .strip_prefix(self.daemon_id)
                .is_some_and(|rest| rest.starts_with(':'))
        })
    }

    fn signal_cancellation(&self, id: Uuid) {
        self.cancellations.lock().request(id);
    }

    /// Fail expired workers without replaying side effects, leaving live leases and queued work untouched.
    pub fn reap_expired_leases(&self, conn: &mut Connection) -> Result<usize, store::StoreError> {
        let now = self.now_rfc3339();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let ids = {
            let mut query = tx.prepare("SELECT id FROM operations WHERE state IN ('running', 'cancelling') AND lease_expires_at IS NOT NULL AND julianday(lease_expires_at) <= julianday(?1)")?;
            query
                .query_map([&now], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut reaped = Vec::new();
        for raw in &ids {
            let id = Uuid::parse_str(raw)
                .map_err(|error| store::StoreError::Sqlite(error.to_string()))?;
            finish_recovered(self, &tx, id, "failed", "OPERATION_LEASE_EXPIRED", &now)?;
            reaped.push(id);
        }
        tx.commit()?;
        for id in reaped {
            self.signal_cancellation(id);
        }
        Ok(ids.len())
    }

    /// Recover only operations with durable reconciliation evidence; fail unsafe restart mutations explicitly.
    pub fn recover_abandoned(
        &self,
        conn: &mut Connection,
    ) -> Result<(RecoveryReport, Vec<RecoveryAction>), store::StoreError> {
        let now = self.clock.now();
        let now_text = self.now_rfc3339();
        let transaction = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let candidates = {
            let mut statement = transaction.prepare(
                "SELECT id, kind, state, stage, resource_id, input_json,
                        lease_owner, lease_expires_at
                   FROM operations
                  WHERE state IN ('queued', 'running', 'cancelling')",
            )?;
            statement
                .query_map([], |row| {
                    let raw_id: String = row.get(0)?;
                    let id = Uuid::parse_str(&raw_id).map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Text,
                            Box::new(error),
                        )
                    })?;
                    Ok(RecoveryCandidate {
                        id,
                        kind: row.get(1)?,
                        state: row.get(2)?,
                        stage: row.get(3)?,
                        resource_id: row.get(4)?,
                        input_json: row.get(5)?,
                        lease_owner: row.get(6)?,
                        lease_expires_at: row.get(7)?,
                    })
                })?
                .collect::<Result<Vec<_>, _>>()?
        };

        let mut report = RecoveryReport::default();
        let mut actions = Vec::new();
        for candidate in candidates {
            // This process is already working on it; recovering it again would repeat the side effect.
            if self.is_mine_and_live(&candidate, now) {
                continue;
            }
            // The durable remote state proves a completed privileged action and permits reconciliation without replay.
            if matches!(candidate.kind.as_str(), "remote.enable" | "remote.disable") {
                let remote: Option<(bool, String, String, Option<String>)> = transaction
                    .query_row(
                        "SELECT enabled, mode, health, hostname FROM remote_access WHERE singleton = 1",
                        [],
                        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
                    )
                    .optional()?;
                let desired_mode = serde_json::from_str::<serde_json::Value>(&candidate.input_json)
                    .ok()
                    .and_then(|value| value.get("mode")?.as_str().map(str::to_owned));
                let converged = match (&candidate.kind, remote.as_ref()) {
                    (kind, Some((true, mode, health, _))) if kind == "remote.enable" => {
                        desired_mode.as_deref() == Some(mode.as_str()) && health != "failed"
                    }
                    (kind, Some((false, mode, _, _))) if kind == "remote.disable" => {
                        mode == "disabled"
                    }
                    _ => false,
                };
                if converged {
                    let (enabled, mode, health, hostname) = remote.unwrap();
                    finish_recovered_success(
                        self,
                        &transaction,
                        candidate.id,
                        &serde_json::json!({
                            "enabled": enabled,
                            "mode": mode,
                            "health": health,
                            "hostname": hostname,
                            "reconciled_after_restart": true,
                        }),
                        &now_text,
                    )?;
                    report.succeeded += 1;
                    continue;
                }
            }
            if candidate.kind == "system.software_updates"
                && candidate.stage.starts_with("runtime_update_")
            {
                let input = serde_json::from_str::<serde_json::Value>(&candidate.input_json).ok();
                let release_id = input
                    .as_ref()
                    .and_then(|value| value.get("runtime_release_id")?.as_str().map(str::to_owned))
                    .filter(|value| spark_privd::update::validate_release_id(value).is_ok());
                if let Some(release_id) = release_id {
                    transaction.execute(
                        "UPDATE operations
                            SET state = 'queued', stage = 'runtime_update_reconciling',
                                updated_at = ?1, completed_at = NULL, error_code = NULL,
                                result_json = NULL, lease_owner = NULL, lease_expires_at = NULL,
                                lease_fence = lease_fence + 1
                          WHERE id = ?2",
                        rusqlite::params![now_text, candidate.id.to_string()],
                    )?;
                    actions.push(RecoveryAction::ReconcileRuntimeUpdate {
                        operation_id: candidate.id,
                        release_id,
                        system_packages: input
                            .as_ref()
                            .and_then(|value| value.get("system_packages"))
                            .and_then(serde_json::Value::as_bool)
                            .unwrap_or(false),
                        firmware: input
                            .as_ref()
                            .and_then(|value| value.get("firmware"))
                            .and_then(serde_json::Value::as_bool)
                            .unwrap_or(false),
                    });
                    report.resumable += 1;
                    continue;
                }
                finish_recovered(
                    self,
                    &transaction,
                    candidate.id,
                    "failed",
                    "OPERATION_RECOVERY_INPUT_INVALID",
                    &now_text,
                )?;
                report.failed += 1;
                continue;
            }
            // Startup recovery resumes predecessor catalogue work before lease expiry because no later pass will run.
            if candidate.kind == "catalogue.refresh" {
                let candidate_json =
                    serde_json::from_str::<serde_json::Value>(&candidate.input_json)
                        .ok()
                        .and_then(|value| value.get("candidate_json")?.as_str().map(str::to_owned))
                        .filter(|value| {
                            !value.is_empty()
                                && value.len() <= crate::catalogue_api::MAX_CATALOGUE_BYTES
                        });
                if let Some(candidate_json) = candidate_json {
                    transaction.execute(
                        "UPDATE operations
                            SET state = 'queued', stage = 'restart_pending', updated_at = ?1,
                                started_at = NULL, completed_at = NULL, error_code = NULL,
                                result_json = NULL, lease_owner = NULL, lease_expires_at = NULL,
                                lease_fence = lease_fence + 1
                          WHERE id = ?2",
                        rusqlite::params![now_text, candidate.id.to_string()],
                    )?;
                    actions.push(RecoveryAction::ResumeCatalogueRefresh {
                        operation_id: candidate.id,
                        candidate_json,
                    });
                    report.resumable += 1;
                    continue;
                }
                finish_recovered(
                    self,
                    &transaction,
                    candidate.id,
                    "failed",
                    "OPERATION_RECOVERY_INPUT_INVALID",
                    &now_text,
                )?;
                report.failed += 1;
                continue;
            }
            let lease_is_live = candidate
                .lease_expires_at
                .as_deref()
                .and_then(|value| {
                    time::OffsetDateTime::parse(
                        value,
                        &time::format_description::well_known::Rfc3339,
                    )
                    .ok()
                })
                .is_some_and(|expiry| expiry > now);
            if lease_is_live {
                continue;
            }

            if candidate.state == "cancelling" {
                finish_recovered(
                    self,
                    &transaction,
                    candidate.id,
                    "cancelled",
                    "OPERATION_CANCELLED_DURING_RESTART",
                    &now_text,
                )?;
                report.cancelled += 1;
                continue;
            }

            if candidate.kind == "model.install" {
                let input = serde_json::from_str::<serde_json::Value>(&candidate.input_json).ok();
                let input_model = input
                    .as_ref()
                    .and_then(|value| value.get("model")?.as_str().map(str::to_owned));
                let provider_credential_id = input
                    .as_ref()
                    .and_then(|value| value.get("provider_credential_id"))
                    .filter(|value| !value.is_null())
                    .and_then(serde_json::Value::as_str)
                    .and_then(|value| Uuid::parse_str(value).ok());
                let credential_input_is_valid = input
                    .as_ref()
                    .and_then(|value| value.get("provider_credential_id"))
                    .is_none_or(|value| {
                        value.is_null()
                            || value
                                .as_str()
                                .is_some_and(|value| Uuid::parse_str(value).is_ok())
                    });
                let model_id = input_model.or(candidate.resource_id);
                if let Some(model_id) = model_id.filter(|_| credential_input_is_valid) {
                    transaction.execute(
                        "UPDATE operations
                            SET state = 'queued', stage = 'restart_pending', updated_at = ?1,
                                started_at = NULL, completed_at = NULL, error_code = NULL,
                                result_json = NULL, lease_owner = NULL, lease_expires_at = NULL,
                                lease_fence = lease_fence + 1
                          WHERE id = ?2",
                        rusqlite::params![now_text, candidate.id.to_string()],
                    )?;
                    actions.push(RecoveryAction::ResumeModelInstall {
                        operation_id: candidate.id,
                        model_id,
                        provider_credential_id,
                    });
                    report.resumable += 1;
                    continue;
                }
                finish_recovered(
                    self,
                    &transaction,
                    candidate.id,
                    "failed",
                    "OPERATION_RECOVERY_INPUT_INVALID",
                    &now_text,
                )?;
                report.failed += 1;
                continue;
            }

            let error_code = if matches!(candidate.kind.as_str(), "model.load" | "model.unload") {
                "OPERATION_ENGINE_STATE_RECONCILIATION_REQUIRED"
            } else {
                "OPERATION_INTERRUPTED_RETRYABLE"
            };
            finish_recovered(
                self,
                &transaction,
                candidate.id,
                "failed",
                error_code,
                &now_text,
            )?;
            report.failed += 1;
        }
        transaction.commit()?;
        Ok((report, actions))
    }
}

fn finish_recovered(
    jobs: &Recovery<'_>,
    conn: &Connection,
    id: Uuid,
    state: &str,
    error_code: &str,
    now: &str,
) -> Result<(), store::StoreError> {
    conn.execute(
        "UPDATE operations
            SET state = ?1, completed_at = ?2, updated_at = ?2, error_code = ?3,
                result_json = NULL, cancellable = 0,
                lease_owner = NULL, lease_expires_at = NULL,
                lease_fence = lease_fence + 1
          WHERE id = ?4",
        rusqlite::params![state, now, error_code, id.to_string()],
    )?;
    crate::audit::append_operation_terminal(
        conn,
        jobs.clock.as_ref(),
        id,
        state,
        Some(error_code),
    )?;
    Ok(())
}

fn finish_recovered_success(
    jobs: &Recovery<'_>,
    conn: &Connection,
    id: Uuid,
    result: &serde_json::Value,
    now: &str,
) -> Result<(), store::StoreError> {
    conn.execute(
        "UPDATE operations
            SET state = 'succeeded', completed_at = ?1, updated_at = ?1, error_code = NULL,
                result_json = ?2, progress = 1.0, stage = 'completed', cancellable = 0,
                lease_owner = NULL, lease_expires_at = NULL,
                lease_fence = lease_fence + 1
          WHERE id = ?3",
        rusqlite::params![now, result.to_string(), id.to_string()],
    )?;
    crate::audit::append_operation_terminal(conn, jobs.clock.as_ref(), id, "succeeded", None)?;
    Ok(())
}
