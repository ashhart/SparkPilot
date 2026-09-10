use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    docker_bin: &String,
    plan_only: bool,
    credentials: credentials::EngineCredentials<'_>,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::StopModel {
            instance_id, force, ..
        } => {
            if plan_only {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned".into(),
                    message: "stop plan approved".into(),
                    details: serde_json::json!({
                        "instance_id": instance_id,
                        "force": force,
                    }),
                });
            }
            let already_absent = if *force {
                let container_name = format!("spark-model-{instance_id}");
                let output = Command::new(docker_bin)
                    .args(["rm", "--force", "--volumes", &container_name])
                    .output()?;
                if output.status.success() {
                    false
                } else if docker_reports_missing_container(&output.stderr) {
                    true
                } else {
                    return Err(BackendError::Failure(format!(
                        "docker forced removal failed: {}",
                        String::from_utf8_lossy(&output.stderr)
                    )));
                }
            } else {
                let container_name = format!("spark-model-{instance_id}");
                let stopped = Command::new(docker_bin)
                    .args(["stop", "--time=30", &container_name])
                    .output()?;
                if !stopped.status.success() && !docker_reports_missing_container(&stopped.stderr) {
                    return Err(BackendError::Failure(format!(
                        "docker stop failed: {}",
                        String::from_utf8_lossy(&stopped.stderr)
                    )));
                }
                if docker_reports_missing_container(&stopped.stderr) {
                    true
                } else {
                    let removed = Command::new(docker_bin)
                        .args(["rm", "--volumes", &container_name])
                        .output()?;
                    if removed.status.success() {
                        false
                    } else if docker_reports_missing_container(&removed.stderr) {
                        true
                    } else {
                        return Err(BackendError::Failure(format!(
                            "docker removal failed: {}",
                            String::from_utf8_lossy(&removed.stderr)
                        )));
                    }
                }
            };
            qwen::restore(*instance_id)?;
            credentials.remove_instance_credential(instance_id);
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "stopped".into(),
                message: "stopped model container".into(),
                details: serde_json::json!({
                    "instance_id": instance_id,
                    "already_absent": already_absent,
                }),
            })
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
