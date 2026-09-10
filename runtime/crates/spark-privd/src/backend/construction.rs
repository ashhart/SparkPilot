use super::*;

impl DockerBackend {
    pub fn new(docker_bin: impl Into<String>, plan_only: bool) -> Self {
        let docker_bin = docker_bin.into();
        let appliance_command_runner: std::sync::Arc<dyn CommandRunner> =
            std::sync::Arc::new(SystemCommandRunner);
        let backend = Self {
            #[cfg(test)]
            kokoro_probe: None,
            plan_only,
            terminals: crate::terminal::TerminalDirector::new(docker_bin.clone()),
            docker_bin,
            models_root: PathBuf::from("/var/lib/spark-runtime/models"),
            worktrees_root: PathBuf::from("/var/lib/spark-runtime/worktrees"),
            runtime_dir: PathBuf::from("/run/spark-runtime"),
            services_root: PathBuf::from("/var/lib/spark-runtime/services"),
            open_webui_root: PathBuf::from("/var/lib/spark-privd/open-webui"),
            #[cfg(test)]
            open_webui_probe: None,
            network_sysfs_root: PathBuf::from("/sys/class/net"),
            power_command_runner: std::sync::Arc::new(SystemCommandRunner),
            hostname_command_runner: std::sync::Arc::new(SystemCommandRunner),
            appliance_command_runner: appliance_command_runner.clone(),
            network_rollbacks: NetworkRollbackManager::production(appliance_command_runner),
            update: crate::update::RuntimeUpdateDirector::new(0),
            service_uid: 0,
            service_gid: 0,
            system_update_state_root: PathBuf::from(SYSTEM_UPDATE_STATE_ROOT),
            engine_cache_root: PathBuf::from(ENGINE_CACHE_ROOT),
            gpu_module_version_path: PathBuf::from(NVIDIA_MODULE_VERSION_PATH),
            gpu_library_dirs: NVML_LIBRARY_DIRS.iter().map(PathBuf::from).collect(),
            tailscale_paths: overlay_ops::TailscalePaths::default(),
            tailscale_mutation: std::sync::Mutex::new(()),
        };
        if !plan_only {
            backend.network_rollbacks.recover();
        }
        backend
    }

    /// Override fixed paths for isolated tests; the privileged protocol never accepts these paths.
    pub fn with_paths(
        mut self,
        models_root: impl Into<PathBuf>,
        runtime_dir: impl Into<PathBuf>,
    ) -> Self {
        self.models_root = models_root.into();
        self.worktrees_root = self
            .models_root
            .parent()
            .unwrap_or(Path::new("/var/lib/spark-runtime"))
            .join("worktrees");
        self.runtime_dir = runtime_dir.into();
        self.open_webui_root = self.runtime_dir.join("open-webui-owned");
        self.services_root = self
            .models_root
            .parent()
            .unwrap_or(Path::new("/var/lib/spark-runtime"))
            .join("services");
        self
    }

    /// Require staged updates to belong to the UID admitted by the peer-credential gate.
    pub fn with_service_uid(mut self, service_uid: u32) -> Self {
        self.update = self.update.with_service_uid(service_uid);
        self.service_uid = service_uid;
        self
    }

    /// Set the engine's service group; an unconfigured helper defaults to root.
    pub fn with_service_gid(mut self, service_gid: u32) -> Self {
        self.service_gid = service_gid;
        self
    }

    /// Inject a scripted command runner into the update director (tests).
    pub fn with_update_runner(
        mut self,
        runner: std::sync::Arc<dyn crate::update::CommandRunner>,
    ) -> Self {
        self.update = self.update.with_runner(runner);
        self
    }

    /// Point the Tailscale binary, apt source and OS release checks at test-owned files; the protocol never accepts them.
    pub fn with_tailscale_paths(mut self, paths: overlay_ops::TailscalePaths) -> Self {
        self.tailscale_paths = paths;
        self
    }

    /// Inject fixed power commands so tests cannot reboot or shut down the host.
    pub fn with_power_command_runner(mut self, runner: std::sync::Arc<dyn CommandRunner>) -> Self {
        self.power_command_runner = runner;
        self
    }

    /// Inject hostnamectl so tests cannot rename the host.
    pub fn with_hostname_command_runner(
        mut self,
        runner: std::sync::Arc<dyn CommandRunner>,
    ) -> Self {
        self.hostname_command_runner = runner;
        self
    }

    /// Inject appliance commands while preserving argv-only execution and secret delivery through stdin.
    pub fn with_appliance_command_runner(
        mut self,
        runner: std::sync::Arc<dyn CommandRunner>,
    ) -> Self {
        self.network_rollbacks.set_runner(runner.clone());
        self.appliance_command_runner = runner;
        self
    }

    /// Redirect interface metadata reads for an isolated policy test.
    pub fn with_network_sysfs_root(mut self, root: impl Into<PathBuf>) -> Self {
        self.network_sysfs_root = root.into();
        self
    }

    /// Override the production 90-second confirmation window for deterministic tests.
    pub fn with_network_rollback_timeout(mut self, timeout: Duration) -> Self {
        self.network_rollbacks.set_timeout(timeout);
        self
    }

    /// Inject the test runner before redirecting the root-owned journal so recovered timers use that runner.
    pub fn with_network_rollback_journal_dir(mut self, directory: impl Into<PathBuf>) -> Self {
        self.network_rollbacks
            .use_test_store(directory.into(), unsafe { libc::geteuid() });
        if !self.plan_only {
            self.network_rollbacks.recover();
        }
        self
    }

    /// Override the OS-update outcome directory for isolated tests.
    pub fn with_system_update_state_root(mut self, root: impl Into<PathBuf>) -> Self {
        self.system_update_state_root = root.into();
        self
    }

    /// Override the host compile-cache directory for isolated tests.
    pub fn with_engine_cache_root(mut self, root: impl Into<PathBuf>) -> Self {
        self.engine_cache_root = root.into();
        self
    }

    /// Point the driver preflight at fixture files so tests never read the host's module or libraries.
    pub fn with_gpu_driver_paths(
        mut self,
        module_version_path: impl Into<PathBuf>,
        library_dirs: Vec<PathBuf>,
    ) -> Self {
        self.gpu_module_version_path = module_version_path.into();
        self.gpu_library_dirs = library_dirs;
        self
    }

    pub fn with_update_director(mut self, update: crate::update::RuntimeUpdateDirector) -> Self {
        self.update = update;
        self
    }
}
