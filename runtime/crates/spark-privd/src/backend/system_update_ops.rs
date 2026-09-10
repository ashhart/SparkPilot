use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    plan_only: bool,
    commands: appliance_commands::ApplianceCommands<'_>,
    system_update_state_root: &Path,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::RefreshSystemUpdates { .. } => {
            let refresh_commands = [
                (APT_GET_BIN, vec!["update".into()]),
                (FWUPDMGR_BIN, vec!["refresh".into(), "--force".into()]),
            ];
            if plan_only {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned".into(),
                    message: "software update refresh plan approved".into(),
                    details: serde_json::json!({
                        "commands": [
                            [APT_GET_BIN, "update"],
                            [FWUPDMGR_BIN, "refresh --force"],
                        ],
                    }),
                });
            }
            for (program, arguments) in refresh_commands {
                // Run metadata refresh outside the helper's read-only package-manager sandbox.
                let output = commands.run_appliance(
                    SYSTEMD_RUN_BIN,
                    host_command_argv(program, &arguments),
                    None,
                )?;
                if !matches!(output.status, Some(0 | 2)) {
                    return Err(BackendError::Failure(format!(
                        "software update metadata refresh failed: {}",
                        output.stderr_text()
                    )));
                }
            }
            Ok(PrivilegedResponse::ok(
                request_id,
                "software_updates_refreshed",
                "software update metadata refreshed",
            ))
        }
        PrivilegedOperation::InstallSystemUpdates {
            system_packages,
            firmware,
            ..
        } => {
            if !system_packages && !firmware {
                return Err(BackendError::InvalidInput(
                    "select at least one update class".into(),
                ));
            }
            // Reuse the request ID for the detached unit and outcome file so status needs no additional identifier.
            let job_id = request_id.to_string();
            let worker = system_update_worker_argv(&job_id, *system_packages, *firmware);
            let plan = serde_json::json!({
                "system_packages": system_packages,
                "firmware": firmware,
                "job_id": job_id,
                "worker": [SYSTEMD_RUN_BIN, worker.clone()],
                "commands": [
                    system_packages.then_some([APT_GET_BIN, "update"]),
                    system_packages.then_some([APT_GET_BIN, "--download-only -y dist-upgrade"]),
                    system_packages.then_some([APT_GET_BIN, "-y dist-upgrade"]),
                    system_packages.then_some([APT_GET_BIN, "check"]),
                    firmware.then_some([FWUPDMGR_BIN, "update -y"]),
                    firmware.then_some([FWUPDMGR_BIN, "get-devices --json"]),
                ],
            });
            if plan_only {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned".into(),
                    message: "software update plan approved".into(),
                    details: plan,
                });
            }
            // Detach long package updates into systemd; the caller polls SystemUpdateStatus while retaining its lease.
            let output = commands.run_appliance(SYSTEMD_RUN_BIN, worker, None)?;
            if !output.success() {
                return Err(BackendError::Failure(format!(
                    "could not start the OS update worker: {}",
                    output.stderr_text()
                )));
            }
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "system_update.scheduled".into(),
                message: "OS update worker scheduled".into(),
                details: serde_json::json!({
                    "job_id": job_id,
                    "unit": system_update_unit_name(&job_id),
                }),
            })
        }
        PrivilegedOperation::SystemUpdateStatus { job_id, .. } => {
            if uuid::Uuid::parse_str(job_id).is_err() {
                return Err(BackendError::InvalidInput(
                    "OS update job id must be a UUID".into(),
                ));
            }
            if plan_only {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned".into(),
                    message: "OS update status plan approved".into(),
                    details: serde_json::json!({ "job_id": job_id }),
                });
            }
            if let Some(outcome) = read_system_update_outcome(system_update_state_root, job_id)? {
                let state = outcome
                    .get("state")
                    .and_then(|value| value.as_str())
                    .unwrap_or("running");
                let (code, message) = match state {
                    "succeeded" => ("system_update.succeeded", "the OS update worker finished"),
                    "failed" => (
                        "system_update.failed",
                        "the OS update worker reported a failure",
                    ),
                    _ => (
                        "system_update.running",
                        "the OS update worker is still running",
                    ),
                };
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: code.into(),
                    message: message.into(),
                    details: outcome,
                });
            }
            // Without an outcome, inspect the unit to distinguish startup from worker failure.
            let unit = system_update_unit_name(job_id);
            let output = commands.run_appliance(
                SYSTEMCTL_BIN,
                vec![
                    "show".into(),
                    "--property=ActiveState".into(),
                    "--value".into(),
                    unit.clone(),
                ],
                None,
            )?;
            let active_state = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            let (code, message) = match active_state.as_str() {
                "active" | "activating" | "reloading" | "deactivating" => {
                    ("system_update.running", "the OS update worker is starting")
                }
                _ => (
                    "UPDATE_SYSTEM_WORKER_LOST",
                    "the OS update worker left no outcome",
                ),
            };
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: code.into(),
                message: message.into(),
                details: serde_json::json!({
                    "job_id": job_id,
                    "unit": unit,
                    "active_state": active_state,
                }),
            })
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
