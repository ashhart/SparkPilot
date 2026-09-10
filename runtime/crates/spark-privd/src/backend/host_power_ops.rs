use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    plan_only: bool,
    power_command_runner: &dyn CommandRunner,
    hostname_command_runner: &dyn CommandRunner,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::Reboot { .. } | PrivilegedOperation::Shutdown { .. } => {
            let (action, args, code, message) = match op {
                PrivilegedOperation::Reboot { .. } => (
                    "reboot",
                    REBOOT_ARGS,
                    "reboot_scheduled",
                    "host reboot scheduled",
                ),
                PrivilegedOperation::Shutdown { .. } => (
                    "shutdown",
                    SHUTDOWN_ARGS,
                    "shutdown_scheduled",
                    "host shutdown scheduled",
                ),
                _ => unreachable!("match arm only accepts power operations"),
            };
            let args = args.map(str::to_owned).to_vec();
            if plan_only {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned".into(),
                    message: format!("host {action} plan approved"),
                    details: serde_json::json!({
                        "program": SYSTEMCTL_BIN,
                        "args": args,
                    }),
                });
            }
            let output = power_command_runner
                .run(SYSTEMCTL_BIN, &args)
                .map_err(BackendError::Failure)?;
            if !output.success() {
                return Err(BackendError::Failure(format!(
                    "failed to schedule host {action}: {}",
                    output.stderr_text()
                )));
            }
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: code.into(),
                message: message.into(),
                details: serde_json::Value::Null,
            })
        }
        PrivilegedOperation::SetHostname { hostname, .. } => {
            if !valid_system_hostname(hostname) {
                return Err(BackendError::InvalidInput(
                    "hostname must be one lowercase label of up to 63 letters, numbers, or hyphens"
                        .into(),
                ));
            }
            let args = vec!["set-hostname".to_owned(), hostname.clone()];
            if plan_only {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned".into(),
                    message: "hostname change plan approved".into(),
                    details: serde_json::json!({
                        "program": HOSTNAMECTL_BIN,
                        "args": args,
                    }),
                });
            }
            let output = hostname_command_runner
                .run(HOSTNAMECTL_BIN, &args)
                .map_err(BackendError::Failure)?;
            if !output.success() {
                return Err(BackendError::Failure(format!(
                    "failed to set hostname: {}",
                    output.stderr_text()
                )));
            }
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "hostname_changed".into(),
                message: "system hostname changed".into(),
                details: serde_json::json!({ "hostname": hostname }),
            })
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
