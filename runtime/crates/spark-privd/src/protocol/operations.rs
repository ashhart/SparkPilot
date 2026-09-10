use super::*;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "operation", rename_all = "snake_case")]
pub enum PrivilegedOperation {
    /// Internal validation probe, unavailable through the public API.
    ProbeContainerRuntime {
        request_id: Uuid,
    },
    /// Read actual managed-profile state from NetworkManager, including after daemon restarts.
    ManagedNetworkProfiles {
        request_id: Uuid,
    },
    /// Read bounded workload facts without lifecycle commands or potentially secret command, environment, label and mount data.
    InventoryWorkloads {
        request_id: Uuid,
    },
    /// Compare recipe-derived adoption policy and return mismatch codes plus an evidence digest without inspected environment values.
    InspectModelAdoption {
        request_id: Uuid,
        policy: crate::adoption::ModelAdoptionPolicy,
    },
    /// Stop the recorded immutable adopted-container ID without removing its container or volumes.
    StopAdoptedModel {
        request_id: Uuid,
        workload_id: String,
        force: bool,
    },
    /// Fetch one digest-pinned engine image for subsequent local launches.
    EnsureEngineImage {
        request_id: Uuid,
        image_digest: String,
    },
    StartModel {
        request_id: Uuid,
        recipe_id: String,
        profile_id: String,
        instance_id: Uuid,
        /// Digest-pinned OCI image from the verified model recipe.
        image_digest: String,
        /// vLLM model alias from the verified recipe.
        served_name: String,
        /// Immutable, already-verified model snapshot mounted read-only.
        model_snapshot: String,
        /// Host-side loopback port selected by sparkd.
        host_port: u16,
        /// Per-instance vLLM API key. Debug formatting is always redacted.
        api_key: SecretString,
        /// Fixed-point value in thousandths (400 means 0.400).
        gpu_memory_utilisation_milli: u16,
        max_model_length: u64,
        max_sequences: u32,
        max_batched_tokens: u64,
        /// Require helper-controlled egress isolation when the verified recipe disallows networking.
        allow_network_during_inference: bool,
        /// Limit container memory to protect the host; None leaves the cap unset.
        #[serde(default)]
        memory_limit_bytes: Option<u64>,
        /// Absolute engine cache budget from the recipe arithmetic (ADR-043); None leaves sizing to the utilisation share.
        #[serde(default)]
        kv_cache_memory_bytes: Option<u64>,
        /// Validate optional recipe engine settings against the helper's own allowlist.
        #[serde(default)]
        engine_options: EngineLaunchOptions,
    },
    StopModel {
        request_id: Uuid,
        instance_id: Uuid,
        force: bool,
    },
    /// Install the bundled WebUI recipe with a write-only first-admin bootstrap password.
    InstallOpenWebUi {
        request_id: Uuid,
        image_digest: String,
        admin_email: String,
        admin_name: String,
        admin_password: SecretString,
        gateway_api_key: SecretString,
        #[serde(default = "crate::protocol::default_open_webui_port")]
        port: u16,
        #[serde(default)]
        adopt_existing: bool,
    },
    UpdateOpenWebUi {
        request_id: Uuid,
        image_digest: String,
    },
    /// Owner-requested, bounded repair of a verified running service.
    RepairOpenWebUi {
        request_id: Uuid,
    },
    RemoveOpenWebUi {
        request_id: Uuid,
        erase_data: bool,
    },
    OpenWebUiStatus {
        request_id: Uuid,
    },
    /// The helper selects the packaged Kokoro image and every launch argument.
    KokoroService {
        request_id: Uuid,
        action: KokoroAction,
    },
    /// The helper selects the packaged search image, writes its settings and fixes every launch argument.
    SearxngService {
        request_id: Uuid,
        action: SearxngAction,
    },
    InstallRuntimeUpdate {
        request_id: Uuid,
        release_id: String,
    },
    /// Read the root-owned outcome left by the detached update worker.
    RuntimeUpdateStatus {
        request_id: Uuid,
        release_id: String,
    },
    ConfigureDirectEthernet {
        request_id: Uuid,
        enabled: bool,
    },
    /// Configure the travel access point, generating omitted credentials with the OS CSPRNG.
    ConfigureTravelAccessPoint {
        request_id: Uuid,
        configuration_id: Uuid,
        enabled: bool,
        ssid: Option<String>,
        passphrase: Option<SecretString>,
    },
    ConnectWifi {
        request_id: Uuid,
        ssid: String,
        passphrase: Option<SecretString>,
        hidden: bool,
    },
    ForgetWifi {
        request_id: Uuid,
        ssid: String,
    },
    /// Resolve the active ordinary LAN internally so callers cannot select fabric interfaces, UUIDs or paths.
    ConfigureLanIpv4 {
        request_id: Uuid,
        configuration_id: Uuid,
        address: Ipv4Addr,
        prefix_length: u8,
        gateway: Ipv4Addr,
        dns_servers: Vec<Ipv4Addr>,
    },
    /// Confirm a network change before its failsafe restores the prior connection.
    ConfirmNetworkChange {
        request_id: Uuid,
        configuration_id: Uuid,
    },
    /// Restore a pending network change immediately.
    RollbackNetworkChange {
        request_id: Uuid,
        configuration_id: Uuid,
    },
    ConfigureBluetooth {
        request_id: Uuid,
        action: BluetoothAction,
        device_address: Option<String>,
    },
    SetPowerProfile {
        request_id: Uuid,
        mode_id: u8,
    },
    /// Refresh metadata before the daemon's bounded read-only availability checks.
    RefreshSystemUpdates {
        request_id: Uuid,
    },
    InstallSystemUpdates {
        request_id: Uuid,
        system_packages: bool,
        firmware: bool,
    },
    /// Outcome of a detached OS update job started by `InstallSystemUpdates`.
    SystemUpdateStatus {
        request_id: Uuid,
        job_id: String,
    },
    ConfigureSystemTime {
        request_id: Uuid,
        timezone: String,
        ntp_enabled: bool,
    },
    PruneContainerStorage {
        request_id: Uuid,
        stopped_containers: bool,
        unused_images: bool,
    },
    /// Install, enable and sign in the vendor Tailscale client with fixed arguments; the owner's browser sign-in is the only input.
    PrepareTailscale {
        request_id: Uuid,
    },
    /// Read the Tailscale client's sign-in and address state without changing it.
    TailscaleStatus {
        request_id: Uuid,
    },
    /// Return only the Spark's VPN and DNS preferences, never the client's private state.
    TailscalePreferences {
        request_id: Uuid,
    },
    /// Change exactly one preference while preserving the existing tailnet and other settings.
    ConfigureTailscale {
        request_id: Uuid,
        enabled: Option<bool>,
        accept_dns: Option<bool>,
    },
    /// Undo exactly what a failed `PrepareTailscale` started: sign out if it signed in, stop and disable the unit if it started it.
    RollBackTailscale {
        request_id: Uuid,
        /// Only true when the same prepare reported that it attempted the owner's sign-in.
        logout: bool,
        /// Only true when the same prepare reported that it started a unit that was not already running.
        disable_service: bool,
    },
    ConfigureClusterLink {
        request_id: Uuid,
        transaction_id: Uuid,
        cluster_id: Uuid,
        local_node_id: Uuid,
        peer_node_id: Uuid,
        local_address: Ipv4Addr,
        peer_address: Ipv4Addr,
        phase: ClusterLinkPhase,
    },
    /// Probe peer reachability only through the exact transaction-owned CX-7 profile selected by the helper.
    ProbeClusterLink {
        request_id: Uuid,
        transaction_id: Uuid,
        cluster_id: Uuid,
        local_node_id: Uuid,
        peer_node_id: Uuid,
        local_address: Ipv4Addr,
        peer_address: Ipv4Addr,
    },
    /// Run fixed collective-validation arguments inside the agreed digest-pinned engine image.
    RunClusterCollectiveTest {
        request_id: Uuid,
        image_digest: String,
    },
    /// Run one concurrent rank of a two-node NCCL all-reduce; local status alone cannot prove collective operation.
    RunClusterTwoRankTest {
        request_id: Uuid,
        transaction_id: Uuid,
        cluster_id: Uuid,
        local_node_id: Uuid,
        peer_node_id: Uuid,
        local_address: Ipv4Addr,
        peer_address: Ipv4Addr,
        coordinator_address: Ipv4Addr,
        node_rank: u8,
        image_digest: String,
    },
    /// Derive Ray role from the signed coordinator identity and launch with helper-owned arguments.
    StartClusterLaunch {
        request_id: Uuid,
        transaction_id: Uuid,
        cluster_id: Uuid,
        launch_id: Uuid,
        local_node_id: Uuid,
        peer_node_id: Uuid,
        coordinator_node_id: Uuid,
        local_address: Ipv4Addr,
        peer_address: Ipv4Addr,
        coordinator_address: Ipv4Addr,
        recipe_id: String,
        profile_id: String,
        /// SHA-256 of the signed catalogue recipe selected by sparkd.
        recipe_digest: String,
        /// Recompute immutable execution-input SHA-256 before creating or reusing a container.
        execution_digest: String,
        image_digest: String,
        served_name: String,
        model_snapshot: String,
        host_port: u16,
        gpu_memory_utilisation_milli: u16,
        max_model_length: u64,
        max_sequences: u32,
        max_batched_tokens: u64,
        /// Permit only the currently qualified two-node topology.
        tensor_parallel_size: u8,
    },
    /// Derive local container and membership checks from immutable launch identifiers.
    ProbeClusterLaunch {
        request_id: Uuid,
        cluster_id: Uuid,
        launch_id: Uuid,
        local_node_id: Uuid,
        peer_node_id: Uuid,
    },
    /// Stop only containers derived from the distributed launch identity.
    StopClusterLaunch {
        request_id: Uuid,
        cluster_id: Uuid,
        launch_id: Uuid,
    },
    /// Launch a validated project plan with pinned image, workspace mounts and allowlisted ports.
    StartProjectContainer {
        request_id: Uuid,
        project_id: Uuid,
        worktree_id: Uuid,
        image_digest: String,
        /// Mount only the validated dedicated agent worktree as /workspace; reject protected checkouts.
        workspace_host_path: String,
        forward_ports: Vec<u16>,
    },
    /// Stop a project dev container started through the typed operation.
    StopProjectContainer {
        request_id: Uuid,
        container_id: String,
    },
    /// Execute a typed tool only inside its project container, without a host fallback.
    RunProjectTool {
        request_id: Uuid,
        project_id: Uuid,
        container_id: String,
        tool: ProjectToolOperation,
    },
    /// Open an allowlisted shell inside a running project container and return its PTY master over the socket.
    OpenProjectTerminal {
        request_id: Uuid,
        project_id: Uuid,
        /// Track the child by the daemon-selected session ID for explicit closure.
        terminal_id: Uuid,
        container_id: String,
        shell: TerminalShell,
        columns: u16,
        rows: u16,
    },
    /// Terminate and reap the interactive child explicitly; dropping its descriptor alone is insufficient.
    CloseProjectTerminal {
        request_id: Uuid,
        terminal_id: Uuid,
    },
    Reboot {
        request_id: Uuid,
    },
    Shutdown {
        request_id: Uuid,
    },
    /// Set a single-label hostname validated by both the caller and privileged backend.
    SetHostname {
        request_id: Uuid,
        hostname: String,
    },
    /// Read helper-selected logs with independently enforced byte and line caps; callers cannot name arbitrary units or containers.
    ReadDiagnosticLog {
        request_id: Uuid,
        source: LogSource,
        max_lines: u32,
    },
}

impl PrivilegedOperation {
    /// The idempotency key shared by every variant.
    pub fn request_id(&self) -> Uuid {
        match self {
            PrivilegedOperation::ProbeContainerRuntime { request_id }
            | PrivilegedOperation::InventoryWorkloads { request_id }
            | PrivilegedOperation::InspectModelAdoption { request_id, .. }
            | PrivilegedOperation::StopAdoptedModel { request_id, .. }
            | PrivilegedOperation::EnsureEngineImage { request_id, .. }
            | PrivilegedOperation::StartModel { request_id, .. }
            | PrivilegedOperation::StopModel { request_id, .. }
            | PrivilegedOperation::InstallOpenWebUi { request_id, .. }
            | PrivilegedOperation::UpdateOpenWebUi { request_id, .. }
            | PrivilegedOperation::RepairOpenWebUi { request_id }
            | PrivilegedOperation::RemoveOpenWebUi { request_id, .. }
            | PrivilegedOperation::OpenWebUiStatus { request_id }
            | PrivilegedOperation::KokoroService { request_id, .. }
            | PrivilegedOperation::SearxngService { request_id, .. }
            | PrivilegedOperation::InstallRuntimeUpdate { request_id, .. }
            | PrivilegedOperation::RuntimeUpdateStatus { request_id, .. }
            | PrivilegedOperation::ConfigureDirectEthernet { request_id, .. }
            | PrivilegedOperation::ConfigureTravelAccessPoint { request_id, .. }
            | PrivilegedOperation::ConnectWifi { request_id, .. }
            | PrivilegedOperation::ForgetWifi { request_id, .. }
            | PrivilegedOperation::ConfigureLanIpv4 { request_id, .. }
            | PrivilegedOperation::ConfirmNetworkChange { request_id, .. }
            | PrivilegedOperation::RollbackNetworkChange { request_id, .. }
            | PrivilegedOperation::ConfigureBluetooth { request_id, .. }
            | PrivilegedOperation::SetPowerProfile { request_id, .. }
            | PrivilegedOperation::RefreshSystemUpdates { request_id }
            | PrivilegedOperation::InstallSystemUpdates { request_id, .. }
            | PrivilegedOperation::SystemUpdateStatus { request_id, .. }
            | PrivilegedOperation::ConfigureSystemTime { request_id, .. }
            | PrivilegedOperation::PruneContainerStorage { request_id, .. }
            | PrivilegedOperation::PrepareTailscale { request_id }
            | PrivilegedOperation::TailscaleStatus { request_id }
            | PrivilegedOperation::TailscalePreferences { request_id }
            | PrivilegedOperation::ConfigureTailscale { request_id, .. }
            | PrivilegedOperation::RollBackTailscale { request_id, .. }
            | PrivilegedOperation::ConfigureClusterLink { request_id, .. }
            | PrivilegedOperation::ProbeClusterLink { request_id, .. }
            | PrivilegedOperation::RunClusterCollectiveTest { request_id, .. }
            | PrivilegedOperation::RunClusterTwoRankTest { request_id, .. }
            | PrivilegedOperation::StartClusterLaunch { request_id, .. }
            | PrivilegedOperation::ProbeClusterLaunch { request_id, .. }
            | PrivilegedOperation::StopClusterLaunch { request_id, .. }
            | PrivilegedOperation::StartProjectContainer { request_id, .. }
            | PrivilegedOperation::ManagedNetworkProfiles { request_id }
            | PrivilegedOperation::StopProjectContainer { request_id, .. }
            | PrivilegedOperation::RunProjectTool { request_id, .. }
            | PrivilegedOperation::OpenProjectTerminal { request_id, .. }
            | PrivilegedOperation::CloseProjectTerminal { request_id, .. }
            | PrivilegedOperation::Reboot { request_id }
            | PrivilegedOperation::Shutdown { request_id }
            | PrivilegedOperation::SetHostname { request_id, .. }
            | PrivilegedOperation::ReadDiagnosticLog { request_id, .. } => *request_id,
        }
    }

    /// Stable machine name of the operation (audit/log classification).
    pub fn kind(&self) -> &'static str {
        match self {
            PrivilegedOperation::ProbeContainerRuntime { .. } => "probe_container_runtime",
            PrivilegedOperation::ManagedNetworkProfiles { .. } => "managed_network_profiles",
            PrivilegedOperation::InventoryWorkloads { .. } => "inventory_workloads",
            PrivilegedOperation::InspectModelAdoption { .. } => "inspect_model_adoption",
            PrivilegedOperation::StopAdoptedModel { .. } => "stop_adopted_model",
            PrivilegedOperation::EnsureEngineImage { .. } => "ensure_engine_image",
            PrivilegedOperation::StartModel { .. } => "start_model",
            PrivilegedOperation::StopModel { .. } => "stop_model",
            PrivilegedOperation::InstallOpenWebUi { .. } => "install_open_webui",
            PrivilegedOperation::UpdateOpenWebUi { .. } => "update_open_webui",
            PrivilegedOperation::RepairOpenWebUi { .. } => "repair_open_webui",
            PrivilegedOperation::RemoveOpenWebUi { .. } => "remove_open_webui",
            PrivilegedOperation::OpenWebUiStatus { .. } => "open_webui_status",
            PrivilegedOperation::KokoroService { action, .. } => match action {
                KokoroAction::Enable => "enable_kokoro",
                KokoroAction::Disable => "disable_kokoro",
                KokoroAction::Status => "kokoro_status",
                KokoroAction::Install => "install_kokoro",
                KokoroAction::Update => "update_kokoro",
                KokoroAction::Remove => "remove_kokoro",
            },
            PrivilegedOperation::SearxngService { action, .. } => match action {
                SearxngAction::Install => "install_searxng",
                SearxngAction::Status => "searxng_status",
                SearxngAction::Remove => "remove_searxng",
            },
            PrivilegedOperation::InstallRuntimeUpdate { .. } => "install_runtime_update",
            PrivilegedOperation::RuntimeUpdateStatus { .. } => "runtime_update_status",
            PrivilegedOperation::ConfigureDirectEthernet { .. } => "configure_direct_ethernet",
            PrivilegedOperation::ConfigureTravelAccessPoint { .. } => "configure_travel_ap",
            PrivilegedOperation::ConnectWifi { .. } => "connect_wifi",
            PrivilegedOperation::ForgetWifi { .. } => "forget_wifi",
            PrivilegedOperation::ConfigureLanIpv4 { .. } => "configure_lan_ipv4",
            PrivilegedOperation::ConfirmNetworkChange { .. } => "confirm_network_change",
            PrivilegedOperation::RollbackNetworkChange { .. } => "rollback_network_change",
            PrivilegedOperation::ConfigureBluetooth { .. } => "configure_bluetooth",
            PrivilegedOperation::SetPowerProfile { .. } => "set_power_profile",
            PrivilegedOperation::RefreshSystemUpdates { .. } => "refresh_system_updates",
            PrivilegedOperation::InstallSystemUpdates { .. } => "install_system_updates",
            PrivilegedOperation::SystemUpdateStatus { .. } => "system_update_status",
            PrivilegedOperation::ConfigureSystemTime { .. } => "configure_system_time",
            PrivilegedOperation::PruneContainerStorage { .. } => "prune_container_storage",
            PrivilegedOperation::PrepareTailscale { .. } => "prepare_tailscale",
            PrivilegedOperation::TailscaleStatus { .. } => "tailscale_status",
            PrivilegedOperation::TailscalePreferences { .. } => "tailscale_preferences",
            PrivilegedOperation::ConfigureTailscale { .. } => "configure_tailscale",
            PrivilegedOperation::RollBackTailscale { .. } => "roll_back_tailscale",
            PrivilegedOperation::ConfigureClusterLink { .. } => "configure_cluster_link",
            PrivilegedOperation::ProbeClusterLink { .. } => "probe_cluster_link",
            PrivilegedOperation::RunClusterCollectiveTest { .. } => "run_cluster_collective_test",
            PrivilegedOperation::RunClusterTwoRankTest { .. } => "run_cluster_two_rank_test",
            PrivilegedOperation::StartClusterLaunch { .. } => "start_cluster_launch",
            PrivilegedOperation::ProbeClusterLaunch { .. } => "probe_cluster_launch",
            PrivilegedOperation::StopClusterLaunch { .. } => "stop_cluster_launch",
            PrivilegedOperation::StartProjectContainer { .. } => "start_project_container",
            PrivilegedOperation::StopProjectContainer { .. } => "stop_project_container",
            PrivilegedOperation::RunProjectTool { .. } => "run_project_tool",
            PrivilegedOperation::OpenProjectTerminal { .. } => "open_project_terminal",
            PrivilegedOperation::CloseProjectTerminal { .. } => "close_project_terminal",
            PrivilegedOperation::Reboot { .. } => "reboot",
            PrivilegedOperation::Shutdown { .. } => "shutdown",
            PrivilegedOperation::SetHostname { .. } => "set_hostname",
            PrivilegedOperation::ReadDiagnosticLog { .. } => "read_diagnostic_log",
        }
    }
}
