use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    plan_only: bool,
    update: &crate::update::RuntimeUpdateDirector,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::InstallRuntimeUpdate { release_id, .. } => {
            if plan_only {
                let argv = update
                    .planned_argv(release_id)
                    .map_err(|error| BackendError::InvalidInput(error.to_string()))?;
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned".into(),
                    message: "runtime update plan approved".into(),
                    details: serde_json::json!({
                        "release_id": release_id,
                        "argv": argv,
                    }),
                });
            }
            let outcome = update
                .schedule(release_id)
                .map_err(|error| BackendError::Failure(error.to_string()))?;
            let details = serde_json::to_value(&outcome)
                .map_err(|error| BackendError::Failure(error.to_string()))?;
            let message = match &outcome {
                crate::update::UpdateOutcome::Scheduled { .. } => {
                    "runtime update worker scheduled".to_owned()
                }
                crate::update::UpdateOutcome::Committed { .. } => {
                    "runtime update committed".to_owned()
                }
                crate::update::UpdateOutcome::AlreadyCommitted { .. } => {
                    "release is already the current commit".to_owned()
                }
                crate::update::UpdateOutcome::RolledBack { .. } => {
                    "update failed; rolled back to the retained previous package".to_owned()
                }
                crate::update::UpdateOutcome::DataRestoredPackageManual { .. } => {
                    "update failed; data restored by the package, but no retained package "
                        .to_owned()
                        + "exists for automatic rollback — complete it manually"
                }
            };
            Ok(PrivilegedResponse {
                request_id,
                accepted: outcome.accepted(),
                code: outcome.code().into(),
                message,
                details,
            })
        }
        PrivilegedOperation::RuntimeUpdateStatus { release_id, .. } => {
            if plan_only {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned".into(),
                    message: "runtime update status plan approved".into(),
                    details: serde_json::json!({ "release_id": release_id }),
                });
            }
            let status = update
                .update_status(release_id)
                .map_err(|error| BackendError::Failure(error.to_string()))?;
            let Some(status) = status else {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "update.unknown".into(),
                    message: "no runtime update outcome is recorded".into(),
                    details: serde_json::json!({ "release_id": release_id }),
                });
            };
            let code = status.code().to_owned();
            let details = serde_json::to_value(&status)
                .map_err(|error| BackendError::Failure(error.to_string()))?;
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code,
                message: if status.is_terminal() {
                    "runtime update reached a terminal outcome".into()
                } else {
                    "runtime update worker is still running".into()
                },
                details,
            })
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
