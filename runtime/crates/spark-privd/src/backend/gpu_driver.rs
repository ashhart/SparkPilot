use super::*;

/// Stable rejection code shared with sparkd and the app: the loaded NVIDIA module and the NVML library disagree.
pub const GPU_DRIVER_MISMATCH: &str = "GPU_DRIVER_MISMATCH";

/// Version of the NVIDIA kernel module the running kernel has loaded.
pub const NVIDIA_MODULE_VERSION_PATH: &str = "/sys/module/nvidia/version";

/// The NVML soname the container prestart hook loads; its symlink target names the installed driver.
pub const NVML_LIBRARY_SONAME: &str = "libnvidia-ml.so.1";

/// Multiarch and legacy library roots searched for the NVML soname.
pub const NVML_LIBRARY_DIRS: [&str; 4] = [
    "/usr/lib/aarch64-linux-gnu",
    "/usr/lib/x86_64-linux-gnu",
    "/usr/lib64",
    "/usr/lib",
];

/// What nvidia-container-cli prints when the installed library cannot talk to the loaded module.
const DOCKER_MISMATCH_MARKER: &str = "driver/library version mismatch";

/// Driver versions the helper can read without opening /dev/nvidia*.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GpuDriverVersions {
    pub kernel_module: Option<String>,
    pub nvml_library: Option<String>,
}

impl GpuDriverVersions {
    /// Only two known, different versions prove a mismatch; missing evidence never blocks a launch.
    pub fn mismatched(&self) -> bool {
        match (&self.kernel_module, &self.nvml_library) {
            (Some(module), Some(library)) => module != library,
            _ => false,
        }
    }
}

/// Filesystem-only probe: PrivateDevices hides the GPU, so compare versions the way NVML will.
pub(super) struct GpuDriverProbe<'a> {
    pub(super) module_version_path: &'a Path,
    pub(super) library_dirs: &'a [PathBuf],
}

impl DockerBackend {
    pub(super) fn gpu_driver(&self) -> GpuDriverProbe<'_> {
        GpuDriverProbe {
            module_version_path: &self.gpu_module_version_path,
            library_dirs: &self.gpu_library_dirs,
        }
    }
}

impl GpuDriverProbe<'_> {
    pub(super) fn observe(&self) -> GpuDriverVersions {
        GpuDriverVersions {
            kernel_module: fs::read_to_string(self.module_version_path)
                .ok()
                .map(|version| version.trim().to_owned())
                .filter(|version| !version.is_empty()),
            nvml_library: self
                .library_dirs
                .iter()
                .find_map(|dir| nvml_library_version(&dir.join(NVML_LIBRARY_SONAME))),
        }
    }
}

/// `libnvidia-ml.so.1 -> libnvidia-ml.so.580.173.02` names the installed userspace driver.
fn nvml_library_version(soname_path: &Path) -> Option<String> {
    let target = fs::read_link(soname_path).ok()?;
    let name = target.file_name()?.to_str()?;
    let version = name.strip_prefix("libnvidia-ml.so.")?;
    (!version.is_empty() && version != "1").then(|| version.to_owned())
}

pub(super) fn docker_reports_driver_mismatch(stderr: &str) -> bool {
    stderr.to_ascii_lowercase().contains(DOCKER_MISMATCH_MARKER)
}

/// Plain-language rejection; the versions and raw docker text travel in details for diagnostics.
pub(super) fn mismatch_rejection(
    request_id: uuid::Uuid,
    versions: &GpuDriverVersions,
    docker_stderr: Option<&str>,
) -> PrivilegedResponse {
    let message = match (&versions.kernel_module, &versions.nvml_library) {
        (Some(module), Some(library)) => format!(
            "the NVIDIA driver on this Spark was updated to {library}, but the running kernel still has driver {module} loaded; restart the Spark, then launch the model again"
        ),
        _ => "the NVIDIA driver on this Spark was updated, but the running kernel still has the old driver loaded; restart the Spark, then launch the model again".to_owned(),
    };
    PrivilegedResponse {
        request_id,
        accepted: false,
        code: GPU_DRIVER_MISMATCH.into(),
        message,
        details: serde_json::json!({
            "kernel_module_version": versions.kernel_module,
            "nvml_library_version": versions.nvml_library,
            "docker_stderr": docker_stderr,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn library_version_comes_from_the_soname_symlink_target() {
        let root = tempfile::tempdir().unwrap();
        let soname = root.path().join(NVML_LIBRARY_SONAME);
        std::os::unix::fs::symlink("libnvidia-ml.so.580.173.02", &soname).unwrap();
        assert_eq!(nvml_library_version(&soname).as_deref(), Some("580.173.02"));

        fs::remove_file(&soname).unwrap();
        std::os::unix::fs::symlink(
            root.path().join("nested/libnvidia-ml.so.590.10.01"),
            &soname,
        )
        .unwrap();
        assert_eq!(nvml_library_version(&soname).as_deref(), Some("590.10.01"));
    }

    #[test]
    fn a_missing_or_regular_soname_yields_no_version() {
        let root = tempfile::tempdir().unwrap();
        let soname = root.path().join(NVML_LIBRARY_SONAME);
        assert_eq!(nvml_library_version(&soname), None);
        fs::write(&soname, b"not a symlink").unwrap();
        assert_eq!(nvml_library_version(&soname), None);
        fs::remove_file(&soname).unwrap();
        std::os::unix::fs::symlink("libnvidia-ml.so.1", &soname).unwrap();
        assert_eq!(nvml_library_version(&soname), None);
    }

    #[test]
    fn only_two_known_different_versions_are_a_mismatch() {
        let known = |module: &str, library: &str| GpuDriverVersions {
            kernel_module: Some(module.to_owned()),
            nvml_library: Some(library.to_owned()),
        };
        assert!(known("580.159.03", "580.173.02").mismatched());
        assert!(!known("580.173.02", "580.173.02").mismatched());
        assert!(
            !GpuDriverVersions {
                kernel_module: Some("580.159.03".into()),
                nvml_library: None,
            }
            .mismatched()
        );
        assert!(!GpuDriverVersions::default().mismatched());
    }

    #[test]
    fn the_docker_marker_is_matched_case_insensitively() {
        assert!(docker_reports_driver_mismatch(
            "nvidia-container-cli: initialization error: nvml error: driver/library version mismatch\n"
        ));
        assert!(docker_reports_driver_mismatch(
            "Failed to initialize NVML: Driver/library version mismatch"
        ));
        assert!(!docker_reports_driver_mismatch(
            "docker: Error response from daemon: No such image"
        ));
    }

    #[test]
    fn the_rejection_names_both_versions_when_known() {
        let versions = GpuDriverVersions {
            kernel_module: Some("580.159.03".into()),
            nvml_library: Some("580.173.02".into()),
        };
        let response = mismatch_rejection(uuid::Uuid::nil(), &versions, Some("raw"));
        assert!(!response.accepted);
        assert_eq!(response.code, GPU_DRIVER_MISMATCH);
        assert!(response.message.contains("580.173.02"));
        assert!(response.message.contains("580.159.03"));
        assert_eq!(response.details["docker_stderr"], "raw");
        let unknown = mismatch_rejection(uuid::Uuid::nil(), &GpuDriverVersions::default(), None);
        assert!(unknown.message.contains("old driver"));
        assert!(unknown.details["kernel_module_version"].is_null());
    }
}
