//! Verify launch allowlists and rejection before Docker execution.

use spark_privd::backend::{
    APT_GET_BIN, ARPING_BIN, BLUETOOTHCTL_BIN, BackendError, CURL_BIN, DockerBackend, FWUPDMGR_BIN,
    HOSTNAMECTL_BIN, INFERENCE_ISOLATED_NETWORK, MAX_MODEL_MEMORY_LIMIT_BYTES,
    NETWORK_ROLLBACK_JOURNAL_FILE, NMCLI_BIN, NVPMODEL_BIN, OpBackend, SPARK_UPDATER_BIN,
    SYSTEMD_RUN_BIN, TAILSCALE_APT_SOURCE_PATH, TAILSCALE_APT_SOURCE_URL, TAILSCALE_BIN,
    TAILSCALE_KEYRING_PATH, TAILSCALE_KEYRING_URL, TAILSCALED_UNIT, TIMEDATECTL_BIN,
    TailscalePaths,
};
use spark_privd::protocol::{
    BluetoothAction, PrivilegedOperation, ProjectGitOperation, ProjectToolOperation, SecretString,
};
use spark_privd::update::{CommandOutput, CommandRunner, RecordingRunner, SYSTEMCTL_BIN};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;
use std::{
    fs,
    os::unix::fs::{MetadataExt as _, PermissionsExt as _},
};
use uuid::Uuid;

fn manual_lan_operation(configuration_id: Uuid) -> PrivilegedOperation {
    PrivilegedOperation::ConfigureLanIpv4 {
        request_id: configuration_id,
        configuration_id,
        address: "192.168.100.63".parse().unwrap(),
        prefix_length: 24,
        gateway: "192.168.100.1".parse().unwrap(),
        dns_servers: vec!["1.1.1.1".parse().unwrap()],
    }
}

#[derive(Default)]
struct BlockingGate {
    started: bool,
    released: bool,
}

struct BlockingLanRunner {
    connection_uuid: Uuid,
    block_activation: bool,
    block_restore: bool,
    calls: Mutex<Vec<(String, Vec<String>)>>,
    activation: (Mutex<BlockingGate>, Condvar),
    restore: (Mutex<BlockingGate>, Condvar),
}

impl BlockingLanRunner {
    fn new(connection_uuid: Uuid, block_activation: bool, block_restore: bool) -> Self {
        Self {
            connection_uuid,
            block_activation,
            block_restore,
            calls: Mutex::new(Vec::new()),
            activation: (Mutex::new(BlockingGate::default()), Condvar::new()),
            restore: (Mutex::new(BlockingGate::default()), Condvar::new()),
        }
    }

    fn wait_started(gate: &(Mutex<BlockingGate>, Condvar), label: &str) {
        let (state, changed) = gate;
        let state = state.lock().unwrap();
        let (state, timeout) = changed
            .wait_timeout_while(state, Duration::from_secs(2), |state| !state.started)
            .unwrap();
        assert!(
            state.started && !timeout.timed_out(),
            "{label} did not start"
        );
    }

    fn release(gate: &(Mutex<BlockingGate>, Condvar)) {
        let (state, changed) = gate;
        state.lock().unwrap().released = true;
        changed.notify_all();
    }

    fn wait_for_activation(&self) {
        Self::wait_started(&self.activation, "activation");
    }

    fn release_activation(&self) {
        Self::release(&self.activation);
    }

    fn restore_started(&self) -> bool {
        self.restore.0.lock().unwrap().started
    }

    fn calls(&self) -> Vec<(String, Vec<String>)> {
        self.calls.lock().unwrap().clone()
    }

    fn wait_for_restore(&self) {
        Self::wait_started(&self.restore, "restore");
    }

    fn release_restore(&self) {
        Self::release(&self.restore);
    }

    fn success(stdout: impl Into<Vec<u8>>) -> Result<CommandOutput, String> {
        Ok(CommandOutput {
            status: Some(0),
            stdout: stdout.into(),
            stderr: Vec::new(),
        })
    }

    fn block(gate: &(Mutex<BlockingGate>, Condvar)) {
        let (state, changed) = gate;
        let mut state = state.lock().unwrap();
        state.started = true;
        changed.notify_all();
        while !state.released {
            state = changed.wait(state).unwrap();
        }
    }
}

impl CommandRunner for BlockingLanRunner {
    fn run(&self, program: &str, args: &[String]) -> Result<CommandOutput, String> {
        self.calls
            .lock()
            .unwrap()
            .push((program.to_owned(), args.to_vec()));
        if program == ARPING_BIN {
            return Self::success(Vec::new());
        }
        if args
            .windows(2)
            .any(|pair| pair == ["ipv4.method", "manual"])
        {
            return Self::success(b"modified\n".to_vec());
        }
        if args.windows(2).any(|pair| pair == ["ipv4.method", "auto"]) {
            if self.block_restore {
                Self::block(&self.restore);
            } else {
                self.restore.0.lock().unwrap().started = true;
                self.restore.1.notify_all();
            }
            return Self::success(b"restored\n".to_vec());
        }
        if args.first().is_some_and(|arg| arg == "--wait") && args.iter().any(|arg| arg == "up") {
            if self.block_activation {
                Self::block(&self.activation);
            }
            return Self::success(b"activated\n".to_vec());
        }
        if args.iter().any(|arg| arg == "--active") {
            return Self::success(format!("{}:ethernet:eno1\n", self.connection_uuid).into_bytes());
        }
        if args.windows(2).any(|pair| pair == ["show", "uuid"]) {
            return Self::success(
                concat!(
                    "ipv4.method:auto\n",
                    "ipv4.addresses:\n",
                    "ipv4.gateway:\n",
                    "ipv4.dns:\n",
                    "ipv4.ignore-auto-dns:no\n"
                )
                .as_bytes()
                .to_vec(),
            );
        }
        if args.iter().any(|arg| arg == "up") {
            return Self::success(b"activated\n".to_vec());
        }
        Err(format!("unexpected command: {program} {args:?}"))
    }

    fn run_with_secret_input(
        &self,
        program: &str,
        args: &[String],
        _secret: &str,
    ) -> Result<CommandOutput, String> {
        self.run(program, args)
    }
}

fn start_operation(instance_id: Uuid) -> PrivilegedOperation {
    let host_port = 18_100 + ((instance_id.as_u128() as u32) % 100) as u16;
    PrivilegedOperation::StartModel {
        request_id: Uuid::new_v4(),
        recipe_id: "example/model-32b".into(),
        profile_id: "balanced-16k".into(),
        instance_id,
        image_digest: format!("nvcr.io/nvidia/vllm@sha256:{}", "a".repeat(64)),
        served_name: "example-32b".into(),
        model_snapshot: "/var/lib/spark-runtime/models/snapshots/example/model-32b/rev".into(),
        host_port,
        api_key: SecretString::new("b".repeat(64)),
        gpu_memory_utilisation_milli: 700,
        max_model_length: 16_384,
        max_sequences: 4,
        max_batched_tokens: 8_192,
        allow_network_during_inference: false,
        memory_limit_bytes: Some(48 * 1024 * 1024 * 1024),
        kv_cache_memory_bytes: None,
        engine_options: Default::default(),
    }
}

fn start_project_operation(worktree_id: Uuid) -> PrivilegedOperation {
    PrivilegedOperation::StartProjectContainer {
        request_id: Uuid::new_v4(),
        project_id: Uuid::new_v4(),
        worktree_id,
        image_digest: format!("example/project@sha256:{}", "c".repeat(64)),
        workspace_host_path: "/var/lib/spark-runtime/projects/example/worktrees/main".into(),
        forward_ports: vec![5173],
    }
}

fn managed_project_fixture() -> (tempfile::TempDir, DockerBackend, PrivilegedOperation) {
    let root = tempfile::tempdir().unwrap();
    let worktree_id = Uuid::new_v4();
    let workspace = root
        .path()
        .join("worktrees")
        .join(format!("agent-{worktree_id}"));
    fs::create_dir_all(&workspace).unwrap();
    let backend = DockerBackend::new("docker", true)
        .with_paths(root.path().join("models"), root.path().join("run"));
    let mut operation = start_project_operation(worktree_id);
    if let PrivilegedOperation::StartProjectContainer {
        workspace_host_path,
        ..
    } = &mut operation
    {
        *workspace_host_path = workspace.display().to_string();
    }
    (root, backend, operation)
}

fn stop_model_operation(instance_id: Uuid, force: bool) -> PrivilegedOperation {
    PrivilegedOperation::StopModel {
        request_id: Uuid::new_v4(),
        instance_id,
        force,
    }
}

include!("backend_policy/scenarios/stopping_an_already_absent_model_container_is_idempotent.rs");

include!(
    "backend_policy/scenarios/network_forbidden_model_uses_the_fixed_internal_network_and_loopback_publish.rs"
);

include!("backend_policy/scenarios/network_allowed_model_keeps_host_loopback_without_a_publish.rs");

include!(
    "backend_policy/scenarios/model_protocol_input_cannot_override_the_fixed_network_policy.rs"
);

include!(
    "backend_policy/scenarios/network_forbidden_start_creates_and_revalidates_the_fixed_namespace_before_run.rs"
);

include!(
    "backend_policy/scenarios/network_forbidden_start_rejects_an_existing_namespace_with_unsafe_options.rs"
);

include!("backend_policy/scenarios/a_driver_library_mismatch_is_refused_before_any_docker_call.rs");

include!("backend_policy/scenarios/a_docker_prestart_driver_mismatch_maps_to_the_typed_code.rs");

include!("backend_policy/scenarios/a_snapshot_swapped_for_a_symlink_during_launch_is_torn_down.rs");

include!("backend_policy/scenarios/model_memory_limit_zero_and_absurd_values_are_refused.rs");
include!(
    "backend_policy/scenarios/an_engine_cache_budget_is_forwarded_as_an_absolute_flag_within_policy.rs"
);

fn operation_host_port(operation: &PrivilegedOperation) -> u16 {
    match operation {
        PrivilegedOperation::StartModel { host_port, .. } => *host_port,
        _ => unreachable!("test operation is start_model"),
    }
}

include!(
    "backend_policy/scenarios/project_plan_uses_a_fixed_bridge_separate_from_every_engine_network.rs"
);

include!("backend_policy/scenarios/project_protocol_input_cannot_override_the_fixed_network.rs");

include!("backend_policy/scenarios/privileged_project_plan_rejects_the_engine_port_range.rs");
include!(
    "backend_policy/scenarios/a_project_container_is_bounded_in_memory_cpu_and_runtime_ports.rs"
);

include!(
    "backend_policy/scenarios/privileged_project_plan_rejects_a_workspace_outside_the_managed_worktree_root.rs"
);

include!("backend_policy/scenarios/project_container_mount_is_rw_and_bound_to_project_labels.rs");

include!("backend_policy/scenarios/project_tool_plan_rejects_host_paths_and_untyped_commands.rs");

include!(
    "backend_policy/scenarios/git_add_fails_when_the_container_did_not_stage_the_requested_path.rs"
);

include!(
    "backend_policy/scenarios/a_workspace_swapped_for_a_symlink_during_launch_is_torn_down.rs"
);

include!(
    "backend_policy/scenarios/privileged_project_plan_rejects_a_managed_name_that_is_a_symlink_escape.rs"
);

include!(
    "backend_policy/scenarios/single_node_launch_accepts_one_million_context_but_refuses_larger_limits.rs"
);

include!(
    "backend_policy/scenarios/invalid_recipe_profile_image_path_port_and_limits_are_rejected.rs"
);

include!("backend_policy/scenarios/operation_debug_output_redacts_the_internal_api_key.rs");

include!(
    "backend_policy/scenarios/open_webui_install_plan_is_pinned_loopback_only_and_keeps_secrets_out_of_argv.rs"
);

include!("backend_policy/scenarios/open_webui_rejects_unpinned_or_wrong_repository_images.rs");

include!("backend_policy/scenarios/startup_cleanup_removes_only_stale_vllm_credentials.rs");

include!("backend_policy/scenarios/power_action_plans_are_fixed_and_do_not_execute.rs");

include!("backend_policy/scenarios/reboot_and_shutdown_execute_only_the_fixed_systemd_argv.rs");

include!(
    "backend_policy/scenarios/power_action_failure_is_reported_without_claiming_acceptance.rs"
);

include!(
    "backend_policy/scenarios/hostname_plan_and_execution_use_only_validated_hostnamectl_argv.rs"
);

include!(
    "backend_policy/scenarios/hostname_rejects_fqdns_uppercase_and_command_text_before_execution.rs"
);

include!("backend_policy/scenarios/appliance_plans_use_only_fixed_programs_and_validated_argv.rs");

include!("backend_policy/scenarios/update_metadata_refresh_accepts_fwupd_nothing_to_do.rs");

include!(
    "backend_policy/scenarios/wifi_secret_never_enters_debug_argv_or_the_failsafe_confirmation.rs"
);

include!(
    "backend_policy/scenarios/manual_lan_ipv4_uses_one_safe_profile_and_restores_it_on_demand.rs"
);

include!("backend_policy/scenarios/manual_lan_ipv4_rejects_a_duplicate_before_profile_mutation.rs");

include!(
    "backend_policy/scenarios/a_pending_network_change_blocks_a_second_change_before_any_mutation.rs"
);

include!(
    "backend_policy/scenarios/the_lan_rollback_timer_starts_only_after_activation_finishes.rs"
);

include!("backend_policy/scenarios/concurrent_lan_changes_cannot_both_reach_network_manager.rs");

include!(
    "backend_policy/scenarios/confirming_while_rollback_executes_reports_the_race_as_a_rejection.rs"
);

include!(
    "backend_policy/scenarios/manual_lan_ipv4_restores_the_journalled_profile_when_modify_fails.rs"
);

include!(
    "backend_policy/scenarios/direct_ethernet_refuses_to_replace_a_connected_management_port.rs"
);

include!(
    "backend_policy/scenarios/direct_ethernet_refuses_unknown_unavailable_and_transitional_port_states.rs"
);

include!(
    "backend_policy/scenarios/direct_ethernet_already_active_is_confirmable_without_reactivating_any_port.rs"
);

include!(
    "backend_policy/scenarios/direct_ethernet_never_selects_protected_fabric_loopback_bridge_or_overlay_interfaces.rs"
);

include!(
    "backend_policy/scenarios/direct_ethernet_fails_closed_when_only_protected_interfaces_exist.rs"
);

include!(
    "backend_policy/scenarios/travel_hotspot_can_register_rollback_and_restore_its_previous_wifi.rs"
);

include!("backend_policy/scenarios/pending_network_rollback_survives_a_helper_restart.rs");

include!("backend_policy/scenarios/expired_network_rollback_runs_and_deletes_its_journal.rs");

include!(
    "backend_policy/scenarios/an_expired_network_rollback_retries_until_the_profile_is_restored.rs"
);

include!(
    "backend_policy/scenarios/resolving_a_missing_network_change_is_a_rejection_not_a_success.rs"
);

include!("backend_policy/scenarios/an_expired_journal_is_rolled_back_when_the_helper_restarts.rs");

include!("backend_policy/scenarios/rollback_journal_never_follows_a_symlink.rs");

include!("backend_policy/scenarios/unsafe_journal_permissions_fail_closed.rs");

include!("backend_policy/scenarios/unsafe_appliance_inputs_are_rejected_before_execution.rs");

include!(
    "backend_policy/scenarios/slow_privileged_operations_declare_an_extended_handling_budget.rs"
);

include!("backend_policy/scenarios/image_preparation_accepts_only_a_digest_pinned_reference.rs");

include!("backend_policy/scenarios/observing_workloads_runs_one_fixed_read_only_projection.rs");

include!("backend_policy/scenarios/observed_output_is_parsed_into_bounded_facts.rs");

include!(
    "backend_policy/scenarios/an_unreadable_container_runtime_is_refused_not_reported_as_empty.rs"
);

include!(
    "backend_policy/scenarios/rows_this_build_cannot_read_are_counted_rather_than_silently_dropped.rs"
);

include!("backend_policy/scenarios/a_planned_observation_executes_nothing.rs");

include!(
    "backend_policy/scenarios/os_update_install_starts_one_detached_worker_and_reports_its_job.rs"
);

include!(
    "backend_policy/scenarios/os_update_install_refuses_an_empty_selection_before_starting_anything.rs"
);

include!("backend_policy/scenarios/os_update_status_reports_the_recorded_outcome.rs");

include!(
    "backend_policy/scenarios/os_update_status_without_an_outcome_asks_the_unit_whether_it_is_alive.rs"
);

include!(
    "backend_policy/scenarios/the_engine_cache_is_created_once_and_handed_to_the_service_account.rs"
);

include!("backend_policy/scenarios/project_container_identity_must_match_its_managed_workspace.rs");

/// The CLI's `status --json` shape for a node that has never signed in.
const TAILSCALE_NEEDS_LOGIN_STATUS: &str = r#"{"BackendState":"NeedsLogin","AuthURL":"","TailscaleIPs":null,"Self":{"HostName":"spark-example","DNSName":"","TailscaleIPs":null},"MagicDNSSuffix":""}"#;

/// A signed-in node with its MagicDNS name and both address families.
const TAILSCALE_RUNNING_STATUS: &str = r#"{"BackendState":"Running","AuthURL":"","TailscaleIPs":["100.96.4.2","fd7a:115c:a1e0::1"],"Self":{"HostName":"spark-example","DNSName":"spark-example.tail1234.ts.net.","TailscaleIPs":["100.96.4.2","fd7a:115c:a1e0::1"],"Online":true},"MagicDNSSuffix":"tail1234.ts.net"}"#;

/// Temporary binary, apt source and os-release so no test touches the host's Tailscale.
fn tailscale_test_paths(installed: bool, apt_source: bool) -> (TailscalePaths, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let binary = dir.path().join("tailscale");
    if installed {
        fs::write(&binary, b"#!/bin/sh\n").unwrap();
    }
    let source = dir.path().join("tailscale.list");
    if apt_source {
        fs::write(
            &source,
            b"deb https://pkgs.tailscale.com/stable/ubuntu noble main\n",
        )
        .unwrap();
    }
    let os_release = dir.path().join("os-release");
    fs::write(&os_release, b"ID=ubuntu\nVERSION_CODENAME=noble\n").unwrap();
    (
        TailscalePaths {
            binary,
            apt_source: source,
            os_release,
        },
        dir,
    )
}

include!(
    "backend_policy/scenarios/tailscale_prepare_uses_fixed_argv_and_returns_the_owner_login_url.rs"
);

include!(
    "backend_policy/scenarios/tailscale_status_reports_ready_with_the_magicdns_name_and_address.rs"
);

include!("backend_policy/scenarios/tailscale_refuses_an_untrusted_login_url.rs");

include!("backend_policy/scenarios/tailscale_prepare_installs_the_vendor_package_when_missing.rs");

include!(
    "backend_policy/scenarios/tailscale_prepare_plan_lists_fixed_commands_and_executes_nothing.rs"
);

include!("backend_policy/scenarios/tailscale_status_without_the_package_reports_not_installed.rs");

include!("backend_policy/scenarios/tailscale_preferences.rs");

#[test]
fn tool_parser_enables_auto_choice_and_rejects_untrusted_flags() {
    use spark_privd::protocol::EngineLaunchOptions;
    let mut options = EngineLaunchOptions::default();
    assert!(options.launch_flags().unwrap().is_empty());
    options.tool_call_parser = Some("qwen3_coder".into());
    assert_eq!(
        options.launch_flags().unwrap(),
        [
            "--enable-auto-tool-choice",
            "--tool-call-parser",
            "qwen3_coder"
        ]
    );
    options.tool_call_parser = Some("--trust-remote-code".into());
    assert!(options.launch_flags().is_err());
}

include!("backend_policy/scenarios/qwen_qualified_launch.rs");
