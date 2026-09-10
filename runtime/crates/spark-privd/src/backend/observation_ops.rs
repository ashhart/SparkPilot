use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    docker_bin: &String,
    commands: appliance_commands::ApplianceCommands<'_>,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::ProbeContainerRuntime { .. } => {
            let status = Command::new(docker_bin)
                .arg("info")
                .output()
                .map_err(|e| BackendError::Failure(format!("docker info: {e}")))?;
            let available = status.status.success();
            // Combine registry and toolkit evidence because DGX OS may support GPUs while listing only runc.
            let gpu_runtime = available
                .then(|| {
                    let registry = std::str::from_utf8(&status.stdout)
                        .ok()
                        .and_then(crate::nvidia_runtime_evidence);
                    let toolkit = crate::nvidia_toolkit_evidence(|path| path.exists());
                    crate::gpu_runtime_evidence(registry, toolkit)
                })
                .flatten();
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: if available {
                    "runtime_available"
                } else {
                    "runtime_unavailable"
                }
                .into(),
                message: "probed container runtime".into(),
                details: serde_json::json!({
                    "available": available,
                    "gpu_runtime": gpu_runtime,
                }),
            })
        }
        PrivilegedOperation::InventoryWorkloads { .. } => {
            // Observe workloads using fixed read-only commands so discovery never disturbs existing services.
            let args = crate::workloads::ps_argv();
            if let Some(plan) = commands.appliance_plan(
                request_id,
                "workload observation plan approved",
                docker_bin,
                &args,
                false,
            ) {
                return Ok(plan);
            }
            let output = commands.run_appliance(docker_bin, args, None)?;
            if !output.success() {
                // Report failed inspection as unavailable; an empty inventory would falsely claim no workloads are running.
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: false,
                    code: "workload_inventory_unavailable".into(),
                    message: "the container runtime could not be inspected".into(),
                    details: serde_json::Value::Null,
                });
            }
            let observed =
                crate::workloads::parse_ps_output(&String::from_utf8_lossy(&output.stdout));
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "workloads_observed".into(),
                message: "observed host workloads without changing any of them".into(),
                details: serde_json::to_value(&observed).map_err(|error| {
                    BackendError::Failure(format!("workload inventory encode: {error}"))
                })?,
            })
        }
        PrivilegedOperation::ManagedNetworkProfiles { .. } => {
            let output = commands.run_appliance(
                NMCLI_BIN,
                vec![
                    "-g".into(),
                    "NAME".into(),
                    "connection".into(),
                    "show".into(),
                    "--active".into(),
                ],
                None,
            )?;
            let active: Vec<&str> = if output.success() {
                std::str::from_utf8(&output.stdout)
                    .unwrap_or_default()
                    .lines()
                    .map(str::trim)
                    .filter(|line| !line.is_empty())
                    .collect()
            } else {
                Vec::new()
            };
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "managed_network_profiles".into(),
                message: "reported the managed network profiles".into(),
                details: serde_json::json!({
                    "direct_profile": active.contains(&DIRECT_PROFILE),
                    "travel_access_point": active.contains(&TRAVEL_PROFILE),
                }),
            })
        }
        PrivilegedOperation::ReadDiagnosticLog {
            source, max_lines, ..
        } => {
            // Derive log arguments only from the closed LogSource enum.
            let lines = (*max_lines).clamp(1, MAX_DIAGNOSTIC_LOG_LINES);
            let (program, args) = match source {
                LogSource::Sparkd | LogSource::SparkPrivd => {
                    let unit = source.systemd_unit().expect("unit-backed source");
                    (
                        JOURNALCTL_BIN,
                        vec![
                            "--unit".to_owned(),
                            unit.to_owned(),
                            "--lines".to_owned(),
                            lines.to_string(),
                            "--no-pager".to_owned(),
                            // Use MESSAGE-only output for the runtime's structured JSON logs.
                            "--output".to_owned(),
                            "cat".to_owned(),
                        ],
                    )
                }
                LogSource::Engine { instance_id } => (
                    docker_bin.as_str(),
                    vec![
                        "logs".to_owned(),
                        format!("--tail={lines}"),
                        format!("spark-model-{instance_id}"),
                    ],
                ),
            };
            if let Some(plan) =
                commands.appliance_plan(request_id, "log tail plan approved", program, &args, false)
            {
                return Ok(plan);
            }
            let output = commands.run_appliance(program, args, None)?;
            if !output.success() {
                // Suppress command stderr because journald and Docker failures can disclose host paths.
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: false,
                    code: "diagnostic_log_unavailable".into(),
                    message: "this log could not be read".into(),
                    details: serde_json::Value::Null,
                });
            }
            // Include Docker stderr as engine output; exclude journalctl stderr because it contains command failures.
            let captured = match source {
                LogSource::Engine { .. } => {
                    [output.stdout.as_slice(), output.stderr.as_slice()].concat()
                }
                _ => output.stdout.clone(),
            };
            Ok(diagnostic_log_response(request_id, *source, &captured))
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
