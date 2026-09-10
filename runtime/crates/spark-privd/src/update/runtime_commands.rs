use super::*;

pub(super) struct RuntimeCommands<'a> {
    pub(super) runner: &'a dyn CommandRunner,
    pub(super) docker_bin: &'a str,
    pub(super) proc_root: &'a Path,
    pub(super) sparkd_bin: &'a Path,
    pub(super) installed_trust_root: &'a Path,
    pub(super) installer_bin: &'a Path,
    pub(super) systemctl_bin: &'a Path,
    pub(super) dpkg_bin: &'a Path,
}

impl RuntimeCommands<'_> {
    /// The only fixed command line the request handler runs (planning mode).
    pub(super) fn planned_argv(
        &self,
        release_id: &str,
    ) -> Result<Vec<(String, Vec<String>)>, UpdateError> {
        validate_release_id(release_id)?;
        Ok(vec![self.schedule_argv(release_id)])
    }

    pub(super) fn schedule_argv(&self, release_id: &str) -> (String, Vec<String>) {
        (
            self.systemctl_bin.to_string_lossy().into_owned(),
            vec![
                "--no-block".into(),
                "start".into(),
                format!("spark-runtime-update@{release_id}.service"),
            ],
        )
    }

    /// Build verification arguments only from validated release IDs, installed trust and fixed filenames.
    pub(super) fn verify_argv(
        &self,
        directory: &Path,
        manifest: &str,
        package: &str,
        signature: &str,
    ) -> (String, Vec<String>) {
        (
            self.installer_bin.to_string_lossy().into_owned(),
            vec![
                "verify-package".into(),
                "--package".into(),
                directory.join(package).to_string_lossy().into_owned(),
                "--signature".into(),
                directory.join(signature).to_string_lossy().into_owned(),
                "--manifest".into(),
                directory.join(manifest).to_string_lossy().into_owned(),
                "--trust-root".into(),
                self.installed_trust_root.to_string_lossy().into_owned(),
                "--installed-trust-root".into(),
                self.installed_trust_root.to_string_lossy().into_owned(),
            ],
        )
    }

    pub(super) fn assert_no_active_workloads(&self) -> Result<(), UpdateError> {
        // Model and project containers must be gone.
        let ps = self.runner.run(
            self.docker_bin,
            &[
                "ps".into(),
                "-q".into(),
                "--filter".into(),
                "name=spark-model-".into(),
                "--filter".into(),
                "name=spark-project-".into(),
            ],
        )?;
        if !ps.stdout.is_empty() {
            return Err(UpdateError::refused(
                "UPDATE_NOT_QUIESCENT engine or project containers are still running",
            ));
        }
        Ok(())
    }

    pub(super) fn stop_runtime_services(&self) -> Result<(), UpdateError> {
        let output = self.runner.run(
            &self.systemctl_bin.to_string_lossy(),
            &[
                "stop".into(),
                "sparkd.service".into(),
                "spark-privd.service".into(),
            ],
        )?;
        if !output.success() {
            return Err(UpdateError::refused(format!(
                "UPDATE_NOT_QUIESCENT systemd could not stop Spark Runtime services: {}",
                truncate(&output.stderr_text(), 2000)
            )));
        }
        Ok(())
    }

    pub(super) fn sparkd_running(&self) -> Result<bool, UpdateError> {
        // Identify live daemons through immutable procfs executable links, skipping zombies and unrelated processes.
        let Ok(entries) = fs::read_dir(self.proc_root) else {
            return Ok(false); // No procfs on development hosts means no observable live daemon.
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if !name.bytes().all(|b| b.is_ascii_digit()) {
                continue;
            }
            if is_zombie(&entry.path()) {
                continue;
            }
            let exe = entry.path().join("exe");
            if let Ok(target) = fs::read_link(&exe) {
                let target = target.to_string_lossy();
                let target = target.trim_end_matches(" (deleted)");
                if target == self.sparkd_bin.to_string_lossy() {
                    return Ok(true);
                }
            }
        }
        Ok(false)
    }

    pub(super) fn run_verifier(
        &self,
        directory: &Path,
        manifest: &str,
        package: &str,
        signature: &str,
    ) -> Result<VerifyReport, UpdateError> {
        let (program, args) = self.verify_argv(directory, manifest, package, signature);
        let output = self.runner.run(&program, &args)?;
        if !output.success() {
            return Err(UpdateError::refused(format!(
                "UPDATE_VERIFICATION_FAILED re-verification failed: {}",
                truncate(&output.stderr_text(), 2000)
            )));
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let text = truncate(&text, MAX_VERIFY_REPORT_BYTES);
        let sha256 = serde_json::from_str::<serde_json::Value>(&text)
            .ok()
            .and_then(|value| {
                value
                    .get("sha256")
                    .and_then(|v| v.as_str())
                    .map(str::to_owned)
            });
        Ok(VerifyReport { sha256 })
    }

    pub(super) fn run_apply(&self, sealed_package: &Path) -> Result<CommandOutput, UpdateError> {
        self.runner
            .run(
                &self.dpkg_bin.to_string_lossy(),
                &["-i".into(), sealed_package.to_string_lossy().into_owned()],
            )
            .map_err(UpdateError::Failure)
    }
}
