//! Validate privileged operations before executing fixed argument vectors without a shell.

mod kokoro;
mod searxng;

mod open_webui;

mod cluster_ops;

use std::collections::HashMap;

use std::fs::{self, OpenOptions};

use std::io::{Read, Write};

use std::net::{Ipv4Addr, SocketAddr, TcpStream};

use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};

use std::path::{Component, Path, PathBuf};

use std::process::{Command, Stdio};

use std::time::{Duration, Instant};

use crate::network_rollback::{
    NetworkChangeResolution, NetworkRollback, NetworkRollbackManager, StoredIpv4Address,
    StoredIpv4Configuration, StoredIpv4Method, valid_stored_ipv4,
};

use crate::protocol::{
    BluetoothAction, ClusterLinkPhase, LogSource, MAX_DIAGNOSTIC_LOG_BYTES,
    MAX_DIAGNOSTIC_LOG_LINES, PrivilegedOperation, PrivilegedResponse,
};

use crate::protocol::{
    valid_lan_ipv4, valid_pinned_image, valid_profile_id, valid_recipe_id, valid_system_hostname,
};

use crate::update::{CommandRunner, SYSTEMCTL_BIN, SystemCommandRunner};

use thiserror::Error;

pub use crate::network_rollback::NETWORK_ROLLBACK_JOURNAL_FILE;

/// Execute validated recipes and runtime-generated identifiers through fixed Docker argument vectors.
pub struct DockerBackend {
    #[cfg(test)]
    kokoro_probe: Option<std::sync::Arc<dyn Fn() -> bool + Send + Sync>>,
    /// Emit the planned argv without executing (tests/planning mode).
    pub plan_only: bool,
    pub docker_bin: String,
    terminals: crate::terminal::TerminalDirector,
    models_root: PathBuf,
    worktrees_root: PathBuf,
    runtime_dir: PathBuf,
    services_root: PathBuf,
    open_webui_root: PathBuf,
    #[cfg(test)]
    open_webui_probe: Option<std::sync::Arc<dyn Fn() -> bool + Send + Sync>>,
    network_sysfs_root: PathBuf,
    power_command_runner: std::sync::Arc<dyn CommandRunner>,
    hostname_command_runner: std::sync::Arc<dyn CommandRunner>,
    appliance_command_runner: std::sync::Arc<dyn CommandRunner>,
    network_rollbacks: NetworkRollbackManager,
    /// Reverify, seal and apply signed updates with retained rollback state.
    update: crate::update::RuntimeUpdateDirector,
    /// Engine UID must match the account admitted by the peer-credential gate and owning the model files.
    service_uid: u32,
    /// Share cache access through the service group because the helper lacks CAP_CHOWN.
    service_gid: u32,
    /// Where the detached OS update worker leaves its outcome.
    system_update_state_root: PathBuf,
    /// The host side of the engine's compile cache.
    engine_cache_root: PathBuf,
    /// Loaded NVIDIA module version and the library roots the launch preflight compares it against.
    gpu_module_version_path: PathBuf,
    gpu_library_dirs: Vec<PathBuf>,
    tailscale_paths: overlay_ops::TailscalePaths,
    tailscale_mutation: std::sync::Mutex<()>,
}

impl DockerBackend {
    const IMAGE_PULL_TIMEOUT: Duration = Duration::from_secs(30 * 60);

    /// Prepare the persistent compile cache at execution time; planning must not modify the filesystem.
    pub fn prepare_engine_cache(&self) -> Result<(), BackendError> {
        self.engine_cache().prepare_engine_cache()
    }

    fn run_appliance(
        &self,
        program: &str,
        args: Vec<String>,
        secret: Option<&str>,
    ) -> Result<crate::update::CommandOutput, BackendError> {
        self.appliance_commands()
            .run_appliance(program, args, secret)
    }

    fn cluster_address_allowed(address: &Ipv4Addr) -> bool {
        spark_core::is_managed_fabric_address(address)
    }

    /// Validate a model operation and construct its container arguments.
    pub fn plan_start_model(
        &self,
        operation: &PrivilegedOperation,
    ) -> Result<ContainerPlan, BackendError> {
        self.model_plan().plan_start_model(operation)
    }

    /// Build project arguments on the ordinary bridge, isolated from inference-only networking and host-loopback engines.
    pub fn plan_start_project_container(
        &self,
        operation: &PrivilegedOperation,
    ) -> Result<ProjectContainerPlan, BackendError> {
        self.project_plan().plan_start_project_container(operation)
    }

    pub fn plan_open_webui_container(
        &self,
        image_digest: &str,
    ) -> Result<OpenWebUiContainerPlan, BackendError> {
        self.webui_plan().plan_open_webui_container(image_digest)
    }

    fn validate_model_snapshot(&self, raw: &str) -> Result<PathBuf, BackendError> {
        self.model_policy().validate_model_snapshot(raw)
    }

    fn open_webui_healthy(&self) -> bool {
        #[cfg(test)]
        if let Some(probe) = &self.open_webui_probe {
            return probe();
        }
        let port = self.open_webui_port();
        let address = SocketAddr::from(([127, 0, 0, 1], port));
        let Ok(mut stream) = TcpStream::connect_timeout(&address, Duration::from_secs(1)) else {
            return false;
        };
        let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
        let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
        if stream
            .write_all(b"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            .is_err()
        {
            return false;
        }
        let mut response = [0u8; 128];
        let Ok(read) = stream.read(&mut response) else {
            return false;
        };
        response[..read].starts_with(b"HTTP/1.1 200")
            || response[..read].starts_with(b"HTTP/1.0 200")
    }

    fn ensure_inference_isolated_network(&self) -> Result<(), BackendError> {
        self.inference_network().ensure_inference_isolated_network()
    }

    /// Delete stale env files after Docker has copied credentials into its container configuration.
    pub fn cleanup_stale_credentials(&self) -> Result<(), BackendError> {
        self.credentials().cleanup_stale_credentials()
    }

    fn pull_image(&self, image_digest: &str) -> Result<(), BackendError> {
        self.engine_image().pull_image(image_digest)
    }
}

impl OpBackend for DockerBackend {
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
        // Reap without signal handlers, which would interfere with Command::output.
        self.terminals.reap_exited();
        if self.plan_only {
            return Ok((
                PrivilegedResponse {
                    request_id: *request_id,
                    accepted: true,
                    code: "planned_terminal".into(),
                    message: "project terminal plan approved".into(),
                    details: serde_json::json!({
                        "argv": self.terminals.argv(container_id, *shell),
                        "terminal_id": terminal_id,
                        "project_id": project_id,
                        "runs_on_host": false,
                    }),
                },
                None,
            ));
        }
        let (master, details) = self.terminals.open(
            *project_id,
            *terminal_id,
            container_id,
            *shell,
            *columns,
            *rows,
        )?;
        Ok((
            PrivilegedResponse {
                request_id: *request_id,
                accepted: true,
                code: "opened_terminal".into(),
                message: "opened project terminal".into(),
                details,
            },
            Some(master),
        ))
    }

    fn execute(&self, op: &PrivilegedOperation) -> Result<PrivilegedResponse, BackendError> {
        let request_id = op.request_id();
        match op {
            PrivilegedOperation::ProbeContainerRuntime { .. }
            | PrivilegedOperation::InventoryWorkloads { .. }
            | PrivilegedOperation::ManagedNetworkProfiles { .. }
            | PrivilegedOperation::ReadDiagnosticLog { .. } => {
                observation_ops::execute(op, &self.docker_bin, self.appliance_commands())
            }
            PrivilegedOperation::InspectModelAdoption { .. }
            | PrivilegedOperation::StopAdoptedModel { .. } => adoption_ops::execute(
                op,
                &self.docker_bin,
                self.plan_only,
                self.workload_ownership(),
            ),
            PrivilegedOperation::EnsureEngineImage { .. } => {
                engine_image_ops::execute(op, self.plan_only, self.engine_image())
            }
            PrivilegedOperation::StartModel { .. } => engine_start::execute(
                op,
                self.plan_only,
                self.model_plan(),
                self.inference_network(),
                self.engine_cache(),
                self.credentials(),
                self.gpu_driver(),
            ),
            PrivilegedOperation::InstallOpenWebUi { .. }
            | PrivilegedOperation::UpdateOpenWebUi { .. }
            | PrivilegedOperation::RepairOpenWebUi { .. }
            | PrivilegedOperation::RemoveOpenWebUi { .. }
            | PrivilegedOperation::OpenWebUiStatus { .. } => self.execute_open_webui(op),
            PrivilegedOperation::KokoroService { .. } => self.execute_kokoro(op),
            PrivilegedOperation::SearxngService { .. } => self.execute_searxng(op),
            PrivilegedOperation::StartProjectContainer { .. }
            | PrivilegedOperation::StopProjectContainer { .. }
            | PrivilegedOperation::RunProjectTool { .. } => project_ops::execute(
                op,
                &self.docker_bin,
                self.plan_only,
                self.workload_ownership(),
                self.project_plan(),
            ),
            PrivilegedOperation::OpenProjectTerminal { .. } => {
                // Opening a terminal requires returning its descriptor; this path cannot report success.
                Err(BackendError::InvalidInput(
                    "opening a terminal requires the descriptor-passing path".into(),
                ))
            }
            PrivilegedOperation::CloseProjectTerminal { terminal_id, .. } => {
                let details = self.terminals.close(*terminal_id)?;
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "closed_terminal".into(),
                    message: "closed project terminal".into(),
                    details,
                })
            }
            PrivilegedOperation::StopModel { .. } => {
                engine_stop::execute(op, &self.docker_bin, self.plan_only, self.credentials())
            }
            PrivilegedOperation::ConnectWifi { .. } | PrivilegedOperation::ForgetWifi { .. } => {
                wifi_ops::execute(
                    op,
                    self.plan_only,
                    self.appliance_commands(),
                    self.network_inspection(),
                    &self.network_rollbacks,
                )
            }
            PrivilegedOperation::ConfigureLanIpv4 { .. } => lan_ops::execute(
                op,
                self.appliance_commands(),
                self.network_inspection(),
                &self.network_rollbacks,
            ),
            PrivilegedOperation::ConfirmNetworkChange { .. }
            | PrivilegedOperation::RollbackNetworkChange { .. } => {
                network_change_ops::execute(op, &self.network_rollbacks)
            }
            PrivilegedOperation::ConfigureDirectEthernet { .. } => direct_link_ops::execute(
                op,
                self.appliance_commands(),
                self.network_inspection(),
                &self.network_rollbacks,
            ),
            PrivilegedOperation::ConfigureTravelAccessPoint { .. } => access_point_ops::execute(
                op,
                self.appliance_commands(),
                self.network_inspection(),
                &self.network_rollbacks,
            ),
            PrivilegedOperation::ConfigureBluetooth { .. }
            | PrivilegedOperation::SetPowerProfile { .. }
            | PrivilegedOperation::ConfigureSystemTime { .. } => {
                host_settings_ops::execute(op, self.appliance_commands())
            }
            PrivilegedOperation::RefreshSystemUpdates { .. }
            | PrivilegedOperation::InstallSystemUpdates { .. }
            | PrivilegedOperation::SystemUpdateStatus { .. } => system_update_ops::execute(
                op,
                self.plan_only,
                self.appliance_commands(),
                &self.system_update_state_root,
            ),
            PrivilegedOperation::PruneContainerStorage { .. } => storage_ops::execute(
                op,
                &self.docker_bin,
                self.plan_only,
                self.appliance_commands(),
            ),
            PrivilegedOperation::Reboot { .. }
            | PrivilegedOperation::Shutdown { .. }
            | PrivilegedOperation::SetHostname { .. } => host_power_ops::execute(
                op,
                self.plan_only,
                self.power_command_runner.as_ref(),
                self.hostname_command_runner.as_ref(),
            ),
            PrivilegedOperation::InstallRuntimeUpdate { .. }
            | PrivilegedOperation::RuntimeUpdateStatus { .. } => {
                runtime_update_ops::execute(op, self.plan_only, &self.update)
            }
            cluster_op @ (PrivilegedOperation::ConfigureClusterLink { .. }
            | PrivilegedOperation::ProbeClusterLink { .. }
            | PrivilegedOperation::RunClusterCollectiveTest { .. }
            | PrivilegedOperation::RunClusterTwoRankTest { .. }
            | PrivilegedOperation::StartClusterLaunch { .. }
            | PrivilegedOperation::ProbeClusterLaunch { .. }
            | PrivilegedOperation::StopClusterLaunch { .. }) => {
                cluster_ops::execute(self, cluster_op)
            }
            PrivilegedOperation::PrepareTailscale { .. }
            | PrivilegedOperation::TailscaleStatus { .. }
            | PrivilegedOperation::RollBackTailscale { .. }
            | PrivilegedOperation::TailscalePreferences { .. }
            | PrivilegedOperation::ConfigureTailscale { .. } => self.execute_overlay(op),
        }
    }
}

#[cfg(test)]
#[path = "backend/ownership_tests.rs"]
mod ownership_tests;

mod command;

mod appliance_commands;

mod overlay_preferences;

impl DockerBackend {
    fn appliance_commands(&self) -> appliance_commands::ApplianceCommands<'_> {
        appliance_commands::ApplianceCommands {
            plan_only: self.plan_only,
            appliance_command_runner: self.appliance_command_runner.as_ref(),
        }
    }
}

mod network_inspection;

impl DockerBackend {
    fn network_inspection(&self) -> network_inspection::NetworkInspection<'_> {
        network_inspection::NetworkInspection {
            network_sysfs_root: &self.network_sysfs_root,
            commands: self.appliance_commands(),
        }
    }
}

mod model_policy;

impl DockerBackend {
    fn model_policy(&self) -> model_policy::ModelPolicy<'_> {
        model_policy::ModelPolicy {
            models_root: &self.models_root,
            plan_only: self.plan_only,
        }
    }
}

mod model_plan;
pub use model_plan::MAX_MODEL_MEMORY_LIMIT_BYTES;

impl DockerBackend {
    fn model_plan(&self) -> model_plan::ModelPlan<'_> {
        model_plan::ModelPlan {
            docker_bin: &self.docker_bin,
            engine_cache_root: &self.engine_cache_root,
            runtime_dir: &self.runtime_dir,
            service_uid: self.service_uid,
            service_gid: self.service_gid,
            model_policy: self.model_policy(),
        }
    }
}

mod workload_ownership;

impl DockerBackend {
    fn workload_ownership(&self) -> workload_ownership::WorkloadOwnership<'_> {
        workload_ownership::WorkloadOwnership {
            docker_bin: &self.docker_bin,
            model_policy: self.model_policy(),
        }
    }
}

mod project_plan;

impl DockerBackend {
    fn project_plan(&self) -> project_plan::ProjectPlan<'_> {
        project_plan::ProjectPlan {
            docker_bin: &self.docker_bin,
            worktrees_root: &self.worktrees_root,
            service_uid: self.service_uid,
            service_gid: self.service_gid,
            plan_only: self.plan_only,
        }
    }
}

mod webui_plan;

impl DockerBackend {
    fn webui_plan(&self) -> webui_plan::WebUiPlan<'_> {
        webui_plan::WebUiPlan {
            docker_bin: &self.docker_bin,
            services_root: &self.services_root,
        }
    }
}

mod gpu_driver;
pub use gpu_driver::{
    GPU_DRIVER_MISMATCH, GpuDriverVersions, NVIDIA_MODULE_VERSION_PATH, NVML_LIBRARY_DIRS,
    NVML_LIBRARY_SONAME,
};

mod engine_cache;

impl DockerBackend {
    fn engine_cache(&self) -> engine_cache::EngineCache<'_> {
        engine_cache::EngineCache {
            engine_cache_root: &self.engine_cache_root,
            service_gid: self.service_gid,
        }
    }
}

mod credentials;

impl DockerBackend {
    fn credentials(&self) -> credentials::EngineCredentials<'_> {
        credentials::EngineCredentials {
            runtime_dir: &self.runtime_dir,
        }
    }
}

mod inference_firewall;
mod inference_network;

impl DockerBackend {
    fn inference_network(&self) -> inference_network::InferenceNetwork<'_> {
        inference_network::InferenceNetwork {
            docker_bin: &self.docker_bin,
            backend: self,
        }
    }
}

mod engine_image;

impl DockerBackend {
    fn engine_image(&self) -> engine_image::EngineImage<'_> {
        engine_image::EngineImage {
            docker_bin: &self.docker_bin,
        }
    }
}

mod policy;

pub use policy::{
    BackendError, OpBackend, host_command_argv, system_update_unit_name, system_update_worker_argv,
};

use policy::{
    CredentialGuard, diagnostic_log_response, docker_reports_missing_container, parse_ipv4_list,
    parse_optional_ipv4, parse_stored_ipv4_addresses, read_system_update_outcome, valid_api_key,
    valid_bluetooth_address, valid_open_webui_admin, valid_open_webui_image, valid_served_name,
    valid_timezone, valid_wifi_passphrase, validate_inference_network,
};

pub(crate) use policy::valid_ssid;

mod fake;

pub use fake::FakeBackend;

mod plans;

use plans::verify_mount_after_launch;
pub use plans::{ContainerPlan, OpenWebUiContainerPlan, ProjectContainerPlan};

mod construction;

mod access_point_ops;

mod adoption_ops;

mod overlay_ops;
pub use overlay_ops::{
    CURL_BIN, TAILSCALE_APT_SOURCE_PATH, TAILSCALE_APT_SOURCE_URL, TAILSCALE_BIN,
    TAILSCALE_KEYRING_PATH, TAILSCALE_KEYRING_URL, TAILSCALED_UNIT, TailscalePaths,
};

mod direct_link_ops;

mod engine_image_ops;

mod engine_start;

mod engine_stop;

mod host_power_ops;

mod host_settings_ops;

mod lan_ops;

mod network_change_ops;

mod observation_ops;

mod project_ops;

mod runtime_update_ops;

mod storage_ops;

mod system_update_ops;

mod wifi_ops;

mod environment;
pub use environment::{
    APT_GET_BIN, ARPING_BIN, BLUETOOTHCTL_BIN, DOCKER_CONFIG_DIR, ENGINE_CACHE_DIR,
    ENGINE_CACHE_ROOT, FWUPDMGR_BIN, HOSTNAMECTL_BIN, INFERENCE_CONTAINER_PORT,
    INFERENCE_ISOLATED_NETWORK, JOURNALCTL_BIN, NMCLI_BIN, NVPMODEL_BIN,
    OPEN_WEBUI_BOOTSTRAP_CONTAINER, OPEN_WEBUI_CONTAINER, OPEN_WEBUI_DATA_VOLUME,
    OPEN_WEBUI_GATEWAY_PORT, OPEN_WEBUI_LOOPBACK_PORT, RFKILL_BIN, SPARK_UPDATER_BIN,
    SYSTEM_UPDATE_STATE_ROOT, SYSTEMD_RUN_BIN, TIMEDATECTL_BIN,
};
pub(crate) use environment::{DIRECT_PROFILE, TRAVEL_PROFILE};
use environment::{
    MAX_SYSTEM_UPDATE_OUTCOME_BYTES, REBOOT_ARGS, SHUTDOWN_ARGS, SPARK_CONTAINER_LABELS,
};

mod fake_observation;

mod qwen;
