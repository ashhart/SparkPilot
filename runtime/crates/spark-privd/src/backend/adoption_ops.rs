use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    docker_bin: &String,
    plan_only: bool,
    ownership: workload_ownership::WorkloadOwnership<'_>,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::InspectModelAdoption { policy, .. } => {
            if plan_only {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned".into(),
                    message: "model adoption inspection plan approved".into(),
                    details: serde_json::json!({
                        "workload_id": policy.workload_id,
                        "returns_secrets": false,
                        "mutates_container": false,
                    }),
                });
            }
            let inspection = ownership.inspect_model_adoption(policy)?;
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "adoption_inspected".into(),
                message: "checked external workload against the model policy".into(),
                details: serde_json::to_value(inspection).map_err(|error| {
                    BackendError::Failure(format!("adoption inspection encode: {error}"))
                })?,
            })
        }
        PrivilegedOperation::StopAdoptedModel {
            workload_id, force, ..
        } => {
            // A syntactically valid container ID proves no ownership; verify the adopted-model policy before stopping it.
            if !crate::adoption::valid_workload_id(workload_id) {
                return Err(BackendError::InvalidInput(
                    "adopted workload id is invalid".into(),
                ));
            }
            if !plan_only {
                ownership.ensure_adopted_model_container(workload_id)?;
            }
            if plan_only {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned".into(),
                    message: "adopted model stop plan approved".into(),
                    details: serde_json::json!({
                        "workload_id": workload_id,
                        "force": force,
                        "removes_container": false,
                    }),
                });
            }
            let action = if *force { "kill" } else { "stop" };
            let output = Command::new(docker_bin)
                .args([action, workload_id])
                .output()?;
            if !output.status.success() {
                return Err(BackendError::Failure(
                    "the adopted container could not be stopped".into(),
                ));
            }
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "adopted_model_stopped".into(),
                message: "stopped adopted model container without removing it".into(),
                details: serde_json::json!({ "workload_id": workload_id }),
            })
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
