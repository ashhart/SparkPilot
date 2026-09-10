//! Accept typed, allowlisted operations over the local authenticated Unix socket.

pub mod adoption;
pub mod backend;
pub mod cpu_power;
pub mod fdpass;
pub mod kokoro;
pub mod mount_pin;
mod network_rollback;
mod project_tools;
pub mod protocol;
pub mod searxng;
pub mod server;
pub mod terminal;
pub mod update;
pub mod workloads;

pub use backend::{BackendError, DockerBackend, FakeBackend, OpBackend};
pub use protocol::{PrivilegedOperation, PrivilegedResponse};
pub use server::default_socket_path;

/// Packaged privileged socket path.
pub const SOCKET_PATH: &str = "/run/spark-runtime/spark-privd.sock";

/// Maximum privileged request size in bytes.
pub const MAX_REQUEST_BYTES: usize = 64 * 1024;

/// Recognize NVIDIA runtime variants including nvidia-cdi and nvidia-legacy.
const NVIDIA_OCI_RUNTIME_FRAGMENT: &str = "nvidia";

/// Known toolkit files provide GPU evidence even when docker info lists only runc.
pub const NVIDIA_TOOLKIT_EVIDENCE_PATHS: &[&str] = &[
    "/usr/bin/nvidia-container-runtime-hook",
    "/usr/bin/nvidia-container-cli",
    "/etc/cdi/nvidia.yaml",
    "/var/run/cdi/nvidia.yaml",
];

/// Probe known toolkit paths directly; unlike an unreadable runtime registry, missing files provide negative evidence.
pub fn nvidia_toolkit_evidence(present: impl Fn(&std::path::Path) -> bool) -> Option<bool> {
    Some(
        NVIDIA_TOOLKIT_EVIDENCE_PATHS
            .iter()
            .any(|path| present(std::path::Path::new(path))),
    )
}

/// Accept GPU support from either NVIDIA runtime registration or installed toolkit evidence.
pub fn gpu_runtime_evidence(registry: Option<bool>, toolkit: Option<bool>) -> Option<bool> {
    if registry == Some(true) || toolkit == Some(true) {
        return Some(true);
    }
    registry.or(toolkit)
}

pub fn nvidia_runtime_evidence(docker_info: &str) -> Option<bool> {
    let mut saw_registry = false;
    let mut found = false;
    for line in docker_info.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = strip_prefix_ignoring_case(trimmed, "runtimes:") {
            saw_registry = true;
            found |= names_nvidia(rest);
        } else if let Some(rest) = strip_prefix_ignoring_case(trimmed, "default runtime:") {
            found |= names_nvidia(rest);
        }
    }
    saw_registry.then_some(found)
}

fn names_nvidia(value: &str) -> bool {
    value
        .split(|c: char| c.is_whitespace() || c == ',')
        .filter(|token| !token.is_empty())
        .any(|token| {
            token
                .to_ascii_lowercase()
                .contains(NVIDIA_OCI_RUNTIME_FRAGMENT)
        })
}

fn strip_prefix_ignoring_case<'a>(value: &'a str, prefix: &str) -> Option<&'a str> {
    let head = value.get(..prefix.len())?;
    head.eq_ignore_ascii_case(prefix)
        .then(|| &value[prefix.len()..])
}

#[cfg(test)]
mod nvidia_runtime_tests {
    use super::*;

    /// Toolkit evidence must permit DGX OS GPU access when its registry lists only runc.
    #[test]
    fn toolkit_on_the_host_counts_as_gpu_evidence_without_a_registered_runtime() {
        let hook_only = |path: &std::path::Path| {
            path == std::path::Path::new("/usr/bin/nvidia-container-runtime-hook")
        };
        assert_eq!(nvidia_toolkit_evidence(hook_only), Some(true));
        assert_eq!(nvidia_toolkit_evidence(|_| false), Some(false));

        let registry_without_nvidia = nvidia_runtime_evidence(
            " Runtimes: io.containerd.runc.v2 runc\n Default Runtime: runc\n",
        );
        assert_eq!(registry_without_nvidia, Some(false));
        assert_eq!(
            gpu_runtime_evidence(registry_without_nvidia, Some(true)),
            Some(true)
        );
        assert_eq!(
            gpu_runtime_evidence(registry_without_nvidia, Some(false)),
            Some(false)
        );
        assert_eq!(gpu_runtime_evidence(None, Some(false)), Some(false));
        assert_eq!(gpu_runtime_evidence(None, None), None);
        assert_eq!(gpu_runtime_evidence(Some(true), Some(false)), Some(true));
    }

    /// Recognize registered NVIDIA runtimes as positive GPU evidence.
    #[test]
    fn a_registered_nvidia_runtime_is_evidence_of_the_toolkit() {
        let info =
            " Server:\n  Runtimes: io.containerd.runc.v2 nvidia runc\n  Default Runtime: runc\n";
        assert_eq!(nvidia_runtime_evidence(info), Some(true));
    }

    #[test]
    fn a_runtimes_line_without_nvidia_is_evidence_of_absence() {
        let info = " Server:\n  Runtimes: io.containerd.runc.v2 runc\n  Default Runtime: runc\n";
        assert_eq!(nvidia_runtime_evidence(info), Some(false));
    }

    /// Missing registry output must remain unknown rather than claim the toolkit is absent.
    #[test]
    fn output_without_a_runtimes_line_is_unknown() {
        assert_eq!(nvidia_runtime_evidence(""), None);
        assert_eq!(
            nvidia_runtime_evidence("Server:\n Storage Driver: overlay2\n"),
            None
        );
        assert_eq!(nvidia_runtime_evidence("total nonsense"), None);
    }

    /// Accept registered NVIDIA runtime-family variants.
    #[test]
    fn newer_toolkit_runtime_variants_count_as_evidence() {
        for line in [
            "  Runtimes: runc nvidia-cdi\n",
            "  Runtimes: runc nvidia-legacy\n",
            "  Runtimes: runc NVIDIA\n",
        ] {
            assert_eq!(nvidia_runtime_evidence(line), Some(true), "{line}");
        }
    }

    #[test]
    fn separators_and_casing_are_tolerated() {
        assert_eq!(
            nvidia_runtime_evidence("  runtimes: runc, nvidia\n"),
            Some(true)
        );
        assert_eq!(
            nvidia_runtime_evidence("Runtimes:\trunc  nvidia\n"),
            Some(true)
        );
    }

    /// An NVIDIA default proves registration; other default-runtime names cannot prove absence.
    #[test]
    fn the_default_runtime_line_is_evidence_but_not_the_registry() {
        assert_eq!(nvidia_runtime_evidence(" Default Runtime: nvidia\n"), None);

        assert_eq!(
            nvidia_runtime_evidence(" Runtimes: runc nvidia\n Default Runtime: nvidia\n"),
            Some(true)
        );

        assert_eq!(
            nvidia_runtime_evidence(
                " Runtimes: io.containerd.runc.v2 runc\n Default Runtime: runc\n"
            ),
            Some(false)
        );
    }
}
