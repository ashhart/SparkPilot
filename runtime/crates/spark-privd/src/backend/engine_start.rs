use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    plan_only: bool,
    model: model_plan::ModelPlan<'_>,
    network: inference_network::InferenceNetwork<'_>,
    cache: engine_cache::EngineCache<'_>,
    credentials: credentials::EngineCredentials<'_>,
    gpu: gpu_driver::GpuDriverProbe<'_>,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::StartModel {
            api_key,
            instance_id,
            ..
        } => {
            let mut plan = model.plan_start_model(op)?;
            if plan_only {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned".into(),
                    message: "container launch plan approved".into(),
                    details: serde_json::json!({
                        "summary": plan.summary,
                        "argv": plan.argv,
                    }),
                });
            }
            // Refuse before any host state changes: the prestart hook would fail the same way after the network, credential and cache work.
            let driver = gpu.observe();
            if driver.mismatched() {
                tracing::warn!(
                    kernel_module = ?driver.kernel_module,
                    nvml_library = ?driver.nvml_library,
                    "refusing model start: NVIDIA driver/library version mismatch"
                );
                return Ok(gpu_driver::mismatch_rejection(request_id, &driver, None));
            }
            if matches!(
                op,
                PrivilegedOperation::StartModel {
                    allow_network_during_inference: false,
                    ..
                }
            ) {
                network.ensure_inference_isolated_network()?;
            }
            let _credential =
                credentials.write_api_credential(&plan.credential_path, api_key.expose_secret())?;
            cache.prepare_for(op)?;
            let memory_policy = if qwen::selected(op) {
                qwen::prepare_launch(&mut plan, op)?;
                Some(qwen::MemoryPolicy::activate(*instance_id)?)
            } else {
                None
            };
            let output = Command::new(&plan.argv[0]).args(&plan.argv[1..]).output()?;
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                // The hook reports the mismatch the preflight could not see; keep docker's text as detail.
                if gpu_driver::docker_reports_driver_mismatch(&stderr) {
                    tracing::warn!(
                        "docker run refused by the NVIDIA prestart hook: driver/library version mismatch"
                    );
                    return Ok(gpu_driver::mismatch_rejection(
                        request_id,
                        &driver,
                        Some(&stderr),
                    ));
                }
                return Err(BackendError::Failure(format!(
                    "docker run failed: {stderr}"
                )));
            }
            // The mount source is a name docker resolved itself; prove it still reaches the directory validated above.
            if let Some(pin) = &plan.snapshot_pin {
                let name = plan.summary["container_name"].as_str().unwrap_or_default();
                verify_mount_after_launch(&plan.argv[0], name, "model snapshot", pin)?;
            }
            if let Some(policy) = memory_policy {
                plan.summary["host_reserved_memory_bytes"] = policy.reserved_bytes.into();
                policy.watch()?;
            }
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "started".into(),
                message: "started model container".into(),
                details: plan.summary,
            })
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
