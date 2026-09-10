use super::*;

#[derive(Debug, Default)]
pub struct FakeBackend {
    /// Override start_model availability to exercise rejection.
    pub runtime_unavailable: bool,
    /// None means GPU-runtime evidence is unknown, not absent.
    pub gpu_runtime: Option<bool>,
    pub observed_operations: std::sync::Arc<std::sync::Mutex<Vec<String>>>,
    pub open_webui_image: std::sync::Arc<std::sync::Mutex<Option<String>>>,
    pub open_webui_connection: std::sync::Arc<std::sync::Mutex<Option<(u16, bool)>>>,
    pub kokoro_image: std::sync::Arc<std::sync::Mutex<Option<String>>>,
    pub kokoro_running: std::sync::Arc<std::sync::atomic::AtomicBool>,
    /// None means inspection failed; tests must explicitly supply inventory evidence.
    pub observed_workloads:
        std::sync::Arc<std::sync::Mutex<Option<crate::workloads::ObservedWorkloads>>>,
    /// Return only supplied adoption evidence; never invent eligibility.
    pub adoption_inspection:
        std::sync::Arc<std::sync::Mutex<Option<crate::adoption::AdoptionInspection>>>,
    /// Script raw diagnostic bytes to exercise production output limits.
    pub scripted_logs: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, Vec<u8>>>>,
    terminals: std::sync::Mutex<std::collections::HashMap<uuid::Uuid, std::os::fd::OwnedFd>>,
}

impl OpBackend for FakeBackend {
    /// Use a process-free PTY to test descriptor passing and resizing through kernel echo.
    fn execute_with_fd(
        &self,
        op: &PrivilegedOperation,
    ) -> Result<(PrivilegedResponse, Option<std::os::fd::OwnedFd>), BackendError> {
        let PrivilegedOperation::OpenProjectTerminal {
            request_id,
            project_id,
            terminal_id,
            container_id,
            shell,
            columns,
            rows,
        } = op
        else {
            return self.execute(op).map(|response| (response, None));
        };
        self.observed_operations
            .lock()
            .expect("fake operation log")
            .push(op.kind().to_owned());
        if !crate::protocol::valid_project_container_id(container_id) {
            return Err(BackendError::InvalidInput(
                "terminals may only be opened in a spark-project-<uuid> container".into(),
            ));
        }
        let winsize = nix::pty::Winsize {
            ws_row: *rows,
            ws_col: *columns,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let nix::pty::OpenptyResult { master, slave } = nix::pty::openpty(Some(&winsize), None)
            .map_err(|errno| BackendError::Failure(format!("openpty: {errno}")))?;
        self.terminals
            .lock()
            .expect("fake terminals")
            .insert(*terminal_id, slave);
        Ok((
            PrivilegedResponse {
                request_id: *request_id,
                accepted: true,
                code: "opened_terminal".into(),
                message: "opened fake project terminal".into(),
                details: serde_json::json!({
                    "terminal_id": terminal_id,
                    "project_id": project_id,
                    "container_id": container_id,
                    "shell": shell.name(),
                    "runs_on_host": false,
                }),
            },
            Some(master),
        ))
    }

    fn execute(&self, op: &PrivilegedOperation) -> Result<PrivilegedResponse, BackendError> {
        self.observed_operations
            .lock()
            .expect("fake operation log")
            .push(op.kind().to_owned());
        let request_id = op.request_id();
        match op {
            PrivilegedOperation::ProbeContainerRuntime { .. } => {
                fake_observation::probe(request_id, self.runtime_unavailable, self.gpu_runtime)
            }
            PrivilegedOperation::ReadDiagnosticLog { source, .. } => {
                fake_observation::diagnostic(request_id, source, &self.scripted_logs)
            }
            PrivilegedOperation::InspectModelAdoption { policy, .. } => {
                let inspection = self
                    .adoption_inspection
                    .lock()
                    .expect("fake adoption inspection")
                    .clone()
                    .filter(|inspection| inspection.workload_id == policy.workload_id);
                match inspection {
                    Some(inspection) => Ok(PrivilegedResponse {
                        request_id,
                        accepted: true,
                        code: "adoption_inspected".into(),
                        message: "checked external workload against the model policy".into(),
                        details: serde_json::to_value(inspection).map_err(|error| {
                            BackendError::Failure(format!("fake adoption encode: {error}"))
                        })?,
                    }),
                    None => Ok(PrivilegedResponse::rejected(
                        request_id,
                        "adoption_inspection_unavailable",
                        "the external workload could not be inspected",
                    )),
                }
            }
            PrivilegedOperation::StopAdoptedModel { workload_id, .. } => {
                if !crate::adoption::valid_workload_id(workload_id) {
                    return Err(BackendError::InvalidInput(
                        "adopted workload id is invalid".into(),
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
            PrivilegedOperation::EnsureEngineImage { image_digest, .. } => Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "image_ready".into(),
                message: "fake engine image is ready".into(),
                details: serde_json::json!({ "image_digest": image_digest, "pulled": false }),
            }),
            PrivilegedOperation::StartModel { instance_id, .. } => {
                if self.runtime_unavailable {
                    return Ok(PrivilegedResponse::rejected(
                        request_id,
                        "runtime_unavailable",
                        "no container runtime available",
                    ));
                }
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "started".into(),
                    message: "started model container".into(),
                    details: serde_json::json!({ "instance_id": instance_id }),
                })
            }
            PrivilegedOperation::StopModel { instance_id, .. } => Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "stopped".into(),
                message: "stopped model container".into(),
                details: serde_json::json!({ "instance_id": instance_id }),
            }),
            PrivilegedOperation::InstallOpenWebUi {
                image_digest,
                port,
                adopt_existing,
                ..
            } => {
                *self
                    .open_webui_connection
                    .lock()
                    .expect("fake WebUI connection") = Some((*port, *adopt_existing));
                *self.open_webui_image.lock().expect("fake Open WebUI state") =
                    Some(image_digest.clone());
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "open_webui_ready".into(),
                    message: "fake Open WebUI service is ready".into(),
                    details: serde_json::json!({
                        "state": "healthy",
                        "image_digest": image_digest,
                        "loopback_port": port,
                    }),
                })
            }
            PrivilegedOperation::UpdateOpenWebUi { image_digest, .. } => {
                *self.open_webui_image.lock().expect("fake Open WebUI state") =
                    Some(image_digest.clone());
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "open_webui_updated".into(),
                    message: "fake Open WebUI service was updated".into(),
                    details: serde_json::json!({
                        "state": "healthy",
                        "image_digest": image_digest,
                    }),
                })
            }
            PrivilegedOperation::RepairOpenWebUi { .. } => Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "open_webui_repaired".into(),
                message: "fake Open WebUI repair completed".into(),
                details: serde_json::json!({"state":"healthy"}),
            }),
            PrivilegedOperation::RemoveOpenWebUi { erase_data, .. } => {
                *self.open_webui_image.lock().expect("fake Open WebUI state") = None;
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "open_webui_removed".into(),
                    message: "fake Open WebUI service was removed".into(),
                    details: serde_json::json!({ "erase_data": erase_data }),
                })
            }
            PrivilegedOperation::KokoroService { action, .. } => {
                use crate::protocol::KokoroAction;
                let mut image = self.kokoro_image.lock().expect("fake Kokoro state");
                let running = &self.kokoro_running;
                match action {
                    KokoroAction::Enable | KokoroAction::Install | KokoroAction::Update => {
                        *image = Some(crate::kokoro::IMAGE.into());
                        running.store(true, std::sync::atomic::Ordering::SeqCst);
                    }
                    KokoroAction::Remove => *image = None,
                    KokoroAction::Disable => {
                        running.store(false, std::sync::atomic::Ordering::SeqCst)
                    }
                    KokoroAction::Status => {}
                }
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "kokoro_service".into(),
                    message: "Kokoro service state".into(),
                    details: serde_json::json!({"installed":image.is_some(),"running":image.is_some() && running.load(std::sync::atomic::Ordering::SeqCst),"healthy":image.is_some() && running.load(std::sync::atomic::Ordering::SeqCst),"image":*image}),
                })
            }
            PrivilegedOperation::OpenWebUiStatus { .. } => {
                let (port, adopted) = self
                    .open_webui_connection
                    .lock()
                    .expect("fake WebUI connection")
                    .unwrap_or((18080, false));
                let image = self
                    .open_webui_image
                    .lock()
                    .expect("fake Open WebUI state")
                    .clone();
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "open_webui_status".into(),
                    message: "fake Open WebUI service status".into(),
                    details: serde_json::json!({
                        "installed": image.is_some(),
                        "running": image.is_some(),
                        "healthy": image.is_some(),
                        "gateway_healthy": image.is_some(),
                        "ownership_verified": image.is_some(),
                        "repair_available": false,
                        "port": port,
                        "adopted": adopted,
                        "image_digest": if adopted { None } else { image },
                    }),
                })
            }
            PrivilegedOperation::StartProjectContainer {
                project_id,
                worktree_id,
                image_digest,
                forward_ports,
                ..
            } => Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "started_project".into(),
                message: "started project container".into(),
                details: serde_json::json!({
                    "project_id": project_id,
                    "worktree_id": worktree_id,
                    "image": image_digest,
                    "forward_ports": forward_ports,
                }),
            }),
            PrivilegedOperation::StopProjectContainer { container_id, .. } => {
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
            } => {
                crate::project_tools::validate(tool)?;
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "project_tool_complete".into(),
                    message: "fake project tool completed inside the container".into(),
                    details: serde_json::json!({
                        "project_id": project_id,
                        "container_id": container_id,
                        "tool": crate::project_tools::tool_name(tool),
                        "ok": true,
                        "exit_code": 0,
                        "output": "",
                    }),
                })
            }
            PrivilegedOperation::InstallRuntimeUpdate { release_id, .. } => {
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "staged".into(),
                    message: "update staged".into(),
                    details: serde_json::json!({ "release_id": release_id }),
                })
            }
            PrivilegedOperation::RuntimeUpdateStatus { release_id, .. } => Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "update.already_committed".into(),
                message: "fake runtime update committed".into(),
                details: serde_json::json!({
                    "state": "completed",
                    "outcome": { "already_committed": { "release_id": release_id } }
                }),
            }),
            PrivilegedOperation::OpenProjectTerminal { .. } => Err(BackendError::InvalidInput(
                "opening a terminal requires the descriptor-passing path".into(),
            )),
            PrivilegedOperation::CloseProjectTerminal { terminal_id, .. } => {
                let removed = self
                    .terminals
                    .lock()
                    .expect("fake terminals")
                    .remove(terminal_id);
                if removed.is_none() {
                    return Err(BackendError::InvalidInput(
                        "no such interactive session".into(),
                    ));
                }
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "closed_terminal".into(),
                    message: "closed fake project terminal".into(),
                    details: serde_json::json!({ "terminal_id": terminal_id }),
                })
            }
            PrivilegedOperation::ConfigureClusterLink {
                transaction_id,
                cluster_id,
                local_node_id,
                peer_node_id,
                local_address,
                peer_address,
                phase,
                ..
            } => Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: match phase {
                    ClusterLinkPhase::Prepare => "cluster_link_prepared",
                    ClusterLinkPhase::Commit => "cluster_link_committed",
                    ClusterLinkPhase::Rollback => "cluster_link_rolled_back",
                }
                .into(),
                message: "fake cluster link transaction completed".into(),
                details: serde_json::json!({
                    "transaction_id": transaction_id,
                    "cluster_id": cluster_id,
                    "local_node_id": local_node_id,
                    "peer_node_id": peer_node_id,
                    "local_address": local_address,
                    "peer_address": peer_address,
                    "phase": phase,
                    "interface": "fake-cx7",
                }),
            }),
            PrivilegedOperation::ProbeClusterLink {
                transaction_id,
                cluster_id,
                local_node_id,
                peer_node_id,
                local_address,
                peer_address,
                ..
            } => Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "cluster_peer_proved".into(),
                message: "fake assigned peer proof completed".into(),
                details: serde_json::json!({
                    "transaction_id": transaction_id,
                    "cluster_id": cluster_id,
                    "local_node_id": local_node_id,
                    "peer_node_id": peer_node_id,
                    "local_address": local_address,
                    "peer_address": peer_address,
                    "interface": "fake-cx7",
                    "local_mac": "02:00:00:00:00:02",
                    "neighbour_mac": "02:00:00:00:00:01",
                    "speed_mbps": 200_000,
                    "mtu": 9_000,
                }),
            }),
            PrivilegedOperation::RunClusterCollectiveTest { image_digest, .. } => {
                if !crate::protocol::valid_pinned_image(image_digest) {
                    return Err(BackendError::InvalidInput(
                        "collective test requires a digest-pinned image".into(),
                    ));
                }
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "collective_test".into(),
                    message: "fake collective validation completed".into(),
                    details: serde_json::json!({ "outcome": "passed" }),
                })
            }
            PrivilegedOperation::RunClusterTwoRankTest {
                transaction_id,
                cluster_id,
                node_rank,
                image_digest,
                ..
            } => {
                if *node_rank > 1 || !valid_pinned_image(image_digest) {
                    return Err(BackendError::InvalidInput(
                        "two-rank collective fields fail cluster policy".into(),
                    ));
                }
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "two_rank_collective_passed".into(),
                    message: "fake two-node NCCL all-reduce completed".into(),
                    details: serde_json::json!({
                        "outcome": "passed",
                        "transaction_id": transaction_id,
                        "cluster_id": cluster_id,
                        "node_rank": node_rank,
                    }),
                })
            }
            PrivilegedOperation::StartClusterLaunch {
                cluster_id,
                launch_id,
                local_node_id,
                peer_node_id,
                coordinator_node_id,
                ..
            } => {
                cluster_ops::validate_start_operation(&DockerBackend::new("docker", true), op)?;
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "cluster_launch_started".into(),
                    message: "fake distributed member process started".into(),
                    details: serde_json::json!({
                        "cluster_id": cluster_id,
                        "launch_id": launch_id,
                        "local_node_id": local_node_id,
                        "peer_node_id": peer_node_id,
                        "coordinator_node_id": coordinator_node_id,
                    }),
                })
            }
            PrivilegedOperation::ProbeClusterLaunch {
                cluster_id,
                launch_id,
                local_node_id,
                peer_node_id,
                ..
            } => {
                if local_node_id == peer_node_id {
                    return Err(BackendError::InvalidInput(
                        "cluster liveness requires two distinct node identities".into(),
                    ));
                }
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "cluster_launch_healthy".into(),
                    message: "fake distributed launch is healthy".into(),
                    details: serde_json::json!({
                        "cluster_id": cluster_id,
                        "launch_id": launch_id,
                        "expected_node_ids": [local_node_id, peer_node_id],
                        "alive_members": 2,
                    }),
                })
            }
            PrivilegedOperation::StopClusterLaunch {
                cluster_id,
                launch_id,
                ..
            } => Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "cluster_launch_stopped".into(),
                message: "fake distributed launch stopped".into(),
                details: serde_json::json!({
                    "cluster_id": cluster_id,
                    "launch_id": launch_id,
                    "stopped": true,
                }),
            }),
            PrivilegedOperation::ConfigureDirectEthernet { enabled, .. } => {
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "direct_profile_configured".into(),
                    message: "fake direct profile updated".into(),
                    details: serde_json::json!({
                        "profile": DIRECT_PROFILE,
                        "enabled": enabled,
                    }),
                })
            }
            PrivilegedOperation::ConfigureTravelAccessPoint { enabled, ssid, .. } => {
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "travel_ap_configured".into(),
                    message: "fake travel access point updated".into(),
                    details: serde_json::json!({
                        "profile": TRAVEL_PROFILE,
                        "enabled": enabled,
                        "ssid": ssid.clone().unwrap_or_else(|| "Spark-FAKE".into()),
                        "passphrase": if *enabled { Some("fake-passphrase-000") } else { None },
                        "security": "wpa3-sae",
                    }),
                })
            }
            PrivilegedOperation::PrepareTailscale { .. }
            | PrivilegedOperation::TailscaleStatus { .. }
            | PrivilegedOperation::RollBackTailscale { .. } => Ok(overlay_ops::fake_response(op)),
            PrivilegedOperation::TailscalePreferences { .. }
            | PrivilegedOperation::ConfigureTailscale { .. } => Ok(PrivilegedResponse::rejected(
                op.request_id(),
                "tailscale_unavailable",
                "Tailscale preferences require the real privileged helper",
            )),
            PrivilegedOperation::InventoryWorkloads { .. } => {
                fake_observation::inventory(request_id, &self.observed_workloads)
            }
            other => Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "accepted".into(),
                message: "fake backend accepted operation".into(),
                details: serde_json::json!({ "operation": other.kind() }),
            }),
        }
    }
}
