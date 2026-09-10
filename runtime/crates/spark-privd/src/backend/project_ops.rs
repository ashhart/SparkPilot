use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    docker_bin: &String,
    plan_only: bool,
    ownership: workload_ownership::WorkloadOwnership<'_>,
    project: project_plan::ProjectPlan<'_>,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::StartProjectContainer { .. } => {
            let plan = project.plan_start_project_container(op)?;
            if plan_only {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned_project".into(),
                    message: "project container plan approved".into(),
                    details: plan.summary,
                });
            }
            let name = plan.summary["container_name"].as_str().unwrap_or_default();
            let inspected = Command::new(docker_bin)
                .args(["inspect", "--format={{.Config.Image}}", name])
                .output()?;
            if inspected.status.success() {
                ownership.ensure_project_container(name)?;
                let PrivilegedOperation::StartProjectContainer {
                    image_digest,
                    project_id,
                    ..
                } = op
                else {
                    unreachable!()
                };
                crate::project_tools::validate_container(docker_bin, false, name, project_id)?;
                if String::from_utf8_lossy(&inspected.stdout).trim() != image_digest {
                    return Err(BackendError::InvalidInput(
                        "The workspace container uses a different image".into(),
                    ));
                }
                let started = Command::new(docker_bin).args(["start", name]).output()?;
                if !started.status.success() {
                    return Err(BackendError::Failure(
                        "Workspace container could not resume".into(),
                    ));
                }
                // A resume mounts the stored source name again, so it is exposed to the same swap as a fresh run.
                verify_mount_after_launch(docker_bin, name, "workspace", &plan.workspace_pin)?;
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "started_project".into(),
                    message: "Workspace container resumed".into(),
                    details: plan.summary,
                });
            }
            let output = Command::new(&plan.argv[0]).args(&plan.argv[1..]).output()?;
            if !output.status.success() {
                return Err(BackendError::Failure(format!(
                    "docker run failed: {}",
                    String::from_utf8_lossy(&output.stderr)
                )));
            }
            verify_mount_after_launch(docker_bin, name, "workspace", &plan.workspace_pin)?;
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "started_project".into(),
                message: "started project container".into(),
                details: plan.summary,
            })
        }
        PrivilegedOperation::StopProjectContainer { container_id, .. } => {
            // Require the full project-container identifier before force removal.
            if !crate::protocol::valid_project_container_id(container_id) {
                return Err(BackendError::InvalidInput(format!(
                    "container id must match spark-project-<uuid>: {container_id}"
                )));
            }
            if !plan_only {
                // Absence must be confirmed by a successful Docker query so retries are idempotent.
                let listed = Command::new(docker_bin)
                    .args([
                        "container",
                        "ls",
                        "--all",
                        "--filter",
                        &format!("name=^{container_id}$"),
                        "--format",
                        "{{.Names}}",
                    ])
                    .output()?;
                if !listed.status.success() {
                    return Err(BackendError::Failure(
                        "could not check project container".into(),
                    ));
                }
                if !String::from_utf8_lossy(&listed.stdout)
                    .lines()
                    .any(|name| name == container_id)
                {
                    return Ok(PrivilegedResponse {
                        request_id,
                        accepted: true,
                        code: "stopped_project".into(),
                        message: "Project container is already removed".into(),
                        details: serde_json::json!({ "container_id": container_id }),
                    });
                }
                // Verify ownership before removing any existing container.
                ownership.ensure_project_container(container_id)?;
            }
            if plan_only {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned_stop".into(),
                    message: "project stop plan approved".into(),
                    details: serde_json::json!({ "container_id": container_id }),
                });
            }
            let mut command = Command::new(docker_bin);
            command
                .arg("rm")
                .arg("--force")
                .arg("--volumes")
                .arg(container_id);
            let output = command.output()?;
            if !output.status.success() {
                return Err(BackendError::Failure(format!(
                    "docker rm failed: {}",
                    String::from_utf8_lossy(&output.stderr)
                )));
            }
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "stopped_project".into(),
                message: "stopped project container".into(),
                details: serde_json::json!({ "container_id": container_id }),
            })
        }
        PrivilegedOperation::RunProjectTool {
            project_id,
            container_id,
            tool,
            ..
        } => project.execute_project_tool(request_id, project_id, container_id, tool),
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
