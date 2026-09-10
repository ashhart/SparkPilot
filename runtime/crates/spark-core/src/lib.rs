//! Mirror canonical SQL constraints and OpenAPI state definitions in shared Rust domain types.

pub mod runtime_version;

/// The runtime source version reported by an unpackaged build.
pub const RUNTIME_VERSION: &str = env!("CARGO_PKG_VERSION");

/// The public control API major version implemented by this build.
pub const API_MAJOR_VERSION: u32 = 1;

/// Reserve inference loopback ports from project binding, forwarding and proxying; sparkd tests pin this shared range (ADR-006).
pub const RESERVED_ENGINE_PORT_RANGE_START: u16 = 18100;
pub const RESERVED_ENGINE_PORT_RANGE_END: u16 = 18199;

/// Reviewed multi-architecture base for managed development workspaces.
pub const DEVELOPMENT_IMAGE: &str =
    "node@sha256:8a34c4ab3ea2c5cd194f07e317b2a8f09461d3c8b05c4e34c8ccd56d56024c4d";

/// Whether `port` falls in the reserved engine range.
pub fn is_reserved_engine_port(port: u16) -> bool {
    (RESERVED_ENGINE_PORT_RANGE_START..=RESERVED_ENGINE_PORT_RANGE_END).contains(&port)
}

/// Loopback ports the runtime's own services bind: Open WebUI, its gateway, Kokoro and the fabric challenge listener.
pub const RUNTIME_SERVICE_PORTS: [u16; 4] = [18080, 18081, 18082, 19443];

/// Whether `port` belongs to the runtime itself, so no project may publish or preview it.
pub fn is_runtime_owned_port(port: u16) -> bool {
    is_reserved_engine_port(port) || RUNTIME_SERVICE_PORTS.contains(&port)
}

/// The private IPv4 /24 Spark Runtime assigns to a fabric it manages itself; nothing else may use it.
pub const MANAGED_FABRIC_PREFIX: [u8; 3] = [172, 31, 252];

/// Whether an observed address belongs to a fabric Spark Runtime configured rather than one it found.
pub fn is_managed_fabric_address(address: &std::net::Ipv4Addr) -> bool {
    let octets = address.octets();
    octets[0..3] == MANAGED_FABRIC_PREFIX && (1..=254).contains(&octets[3])
}

/// Unified memory a project container may hold, matching `[projects] default_memory_limit_bytes`.
pub const PROJECT_CONTAINER_MEMORY_BYTES: u64 = 34_359_738_368;

/// CPU ceiling for a project container, matching `[projects] default_cpu_limit`.
pub const PROJECT_CONTAINER_CPUS: u32 = 8;
/// The world-readable banner naming the loaded NVIDIA kernel module, the only host software version an unprivileged runtime can read.
pub const NVIDIA_DRIVER_VERSION_PATH: &str = "/proc/driver/nvidia/version";

/// Extract the kernel-module version from a driver banner; an unfamiliar banner yields nothing rather than a guess.
pub fn nvidia_kernel_module_version(banner: &str) -> Option<&str> {
    banner
        .lines()
        .next()
        .and_then(|line| line.split_once("Kernel Module"))
        .and_then(|(_, rest)| rest.split_whitespace().next())
        .filter(|token| {
            token
                .chars()
                .all(|character| character.is_ascii_digit() || character == '.')
        })
}

/// This node's accelerator driver version, read once because loading another module requires a restart.
pub fn host_driver_version() -> Option<&'static str> {
    static VERSION: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();
    VERSION
        .get_or_init(|| {
            std::fs::read_to_string(NVIDIA_DRIVER_VERSION_PATH)
                .ok()
                .and_then(|banner| nvidia_kernel_module_version(&banner).map(str::to_owned))
        })
        .as_deref()
}

#[cfg(test)]
mod driver_version_tests {
    use super::nvidia_kernel_module_version;

    #[test]
    fn only_a_dotted_numeric_token_after_kernel_module_is_a_version() {
        assert_eq!(
            nvidia_kernel_module_version(
                "NVRM version: NVIDIA UNIX x86_64 Kernel Module  580.65.06  Tue Aug 12 10:00:00 UTC 2025\n"
            ),
            Some("580.65.06")
        );
        assert_eq!(nvidia_kernel_module_version("something else\n"), None);
        assert_eq!(
            nvidia_kernel_module_version("NVRM version: Kernel Module unknown\n"),
            None
        );
    }
}

pub mod identity;
pub mod notify;

pub use identity::{NodeIdentity, PublicIdentity};
