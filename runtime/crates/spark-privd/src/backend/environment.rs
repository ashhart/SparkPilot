/// The protocol selects these fixed power actions without accepting caller-supplied arguments.
pub(super) const REBOOT_ARGS: [&str; 2] = ["reboot", "--no-block"];

pub(super) const SHUTDOWN_ARGS: [&str; 2] = ["poweroff", "--no-block"];

pub const HOSTNAMECTL_BIN: &str = "/usr/bin/hostnamectl";

pub const NMCLI_BIN: &str = "/usr/bin/nmcli";

pub const ARPING_BIN: &str = "/usr/bin/arping";

pub const RFKILL_BIN: &str = "/usr/sbin/rfkill";

pub const BLUETOOTHCTL_BIN: &str = "/usr/bin/bluetoothctl";

pub const NVPMODEL_BIN: &str = "/usr/sbin/nvpmodel";

pub const TIMEDATECTL_BIN: &str = "/usr/bin/timedatectl";

pub const APT_GET_BIN: &str = "/usr/bin/apt-get";

pub const FWUPDMGR_BIN: &str = "/usr/bin/fwupdmgr";

/// Run fixed OS-update commands through systemd while keeping the helper filesystem read-only; see docs/development/privileged-boundaries.md.
pub const SYSTEMD_RUN_BIN: &str = "/usr/bin/systemd-run";

/// The packaged updater, which also carries the detached OS update worker.
pub const SPARK_UPDATER_BIN: &str = "/usr/lib/spark-runtime/spark-updater";

/// Where the detached OS update worker records its outcome (root, 0700).
pub const SYSTEM_UPDATE_STATE_ROOT: &str = "/var/lib/spark-privd/os-updates";

/// Largest outcome file the status query will read.
pub(super) const MAX_SYSTEM_UPDATE_OUTCOME_BYTES: u64 = 256 * 1024;

/// Labels identifying runtime-owned containers for ownership checks.
pub(super) const SPARK_CONTAINER_LABELS: [&str; 4] = [
    "spark.project_id",
    "spark.cluster",
    "spark.local",
    "spark.transaction",
];

/// Writable, executable container cache for compiled kernels; the root remains read-only and /tmp remains noexec.
pub const ENGINE_CACHE_DIR: &str = "/engine-cache";

/// Host cache shared with the engine through the service account's group.
pub const ENGINE_CACHE_ROOT: &str = "/var/lib/spark-privd/engine-cache";

/// Docker CLI config home for the helper's `docker` children; ProtectHome makes /root/.docker unreadable and every command would warn.
pub const DOCKER_CONFIG_DIR: &str = "/var/lib/spark-privd/docker";

pub const JOURNALCTL_BIN: &str = "/usr/bin/journalctl";

pub const OPEN_WEBUI_CONTAINER: &str = "spark-open-webui";

pub const OPEN_WEBUI_BOOTSTRAP_CONTAINER: &str = "spark-open-webui-bootstrap";

pub const OPEN_WEBUI_DATA_VOLUME: &str = "spark-open-webui-data";

pub const OPEN_WEBUI_LOOPBACK_PORT: u16 = 18080;

pub const OPEN_WEBUI_GATEWAY_PORT: u16 = 18081;

pub const INFERENCE_ISOLATED_NETWORK: &str = "spark-inference-isolated";

pub const INFERENCE_CONTAINER_PORT: u16 = 8000;

pub(crate) const DIRECT_PROFILE: &str = "SparkPilot-Direct";

pub(crate) const TRAVEL_PROFILE: &str = "SparkPilot-Travel";

#[cfg(test)]
mod port_reservation_tests {
    /// Every loopback port the helper binds for a runtime service must be reserved where projects are validated.
    #[test]
    fn runtime_service_ports_are_reserved_in_spark_core() {
        for port in [
            super::OPEN_WEBUI_LOOPBACK_PORT,
            super::OPEN_WEBUI_GATEWAY_PORT,
            crate::kokoro::PORT,
            crate::protocol::CLUSTER_FABRIC_CHALLENGE_PORT,
        ] {
            assert!(
                spark_core::is_runtime_owned_port(port),
                "{port} must be reserved"
            );
        }
    }
}
