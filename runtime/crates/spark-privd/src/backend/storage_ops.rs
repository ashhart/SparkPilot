use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    docker_bin: &String,
    plan_only: bool,
    commands: appliance_commands::ApplianceCommands<'_>,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::PruneContainerStorage {
            stopped_containers,
            unused_images,
            ..
        } => {
            if !stopped_containers && !unused_images {
                return Err(BackendError::InvalidInput(
                    "select at least one container cleanup class".into(),
                ));
            }
            if plan_only {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned".into(),
                    message: "container cleanup plan approved".into(),
                    details: serde_json::json!({
                        "program": docker_bin,
                        "stopped_containers": stopped_containers,
                        "unused_images": unused_images,
                    }),
                });
            }
            if *stopped_containers {
                // Prune owned label families separately because Docker combines multiple label filters with AND.
                for label in SPARK_CONTAINER_LABELS {
                    let output = commands.run_appliance(
                        docker_bin,
                        vec![
                            "container".into(),
                            "prune".into(),
                            "--force".into(),
                            format!("--filter=label={label}"),
                        ],
                        None,
                    )?;
                    if !output.success() {
                        return Err(BackendError::Failure(
                            "stopped-container cleanup failed".into(),
                        ));
                    }
                }
            }
            if *unused_images {
                // Omit --all so tagged images remain available to their owners.
                let output = commands.run_appliance(
                    docker_bin,
                    vec!["image".into(), "prune".into(), "--force".into()],
                    None,
                )?;
                if !output.success() {
                    return Err(BackendError::Failure("unused-image cleanup failed".into()));
                }
            }
            Ok(PrivilegedResponse::ok(
                request_id,
                "container_storage_pruned",
                "selected container storage was reclaimed",
            ))
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
