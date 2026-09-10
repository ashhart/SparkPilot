//! Apply only a root-owned, reverified release seal; see ADR-019 for scheduling and rollback guarantees.

use std::fs;

use std::io::{Read, Write};

use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

use std::path::{Path, PathBuf};

use std::sync::Arc;

use parking_lot::Mutex;

use serde::{Deserialize, Serialize};

use sha2::Digest;

use thiserror::Error;

/// Lock the persistent staging parent across validation and sealing; descriptor closure releases it without timestamp heuristics.
pub fn acquire_staging_lock(staging_root: &Path, exclusive: bool) -> std::io::Result<fs::File> {
    use std::os::fd::AsRawFd;

    let directory = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY | libc::O_CLOEXEC)
        .open(staging_root)?;
    let operation = if exclusive {
        libc::LOCK_EX
    } else {
        libc::LOCK_SH
    };
    // SAFETY: directory owns the open descriptor throughout this call and transfers it to the returned guard.
    if unsafe { libc::flock(directory.as_raw_fd(), operation | libc::LOCK_NB) } != 0 {
        let error = std::io::Error::last_os_error();
        return Err(if error.kind() == std::io::ErrorKind::WouldBlock {
            std::io::Error::new(
                error.kind(),
                "UPDATE_STAGING_BUSY another process is staging or sealing an update; retry shortly",
            )
        } else {
            error
        });
    }
    Ok(directory)
}

/// Directs one signed runtime-update transaction for the privileged helper.
pub struct RuntimeUpdateDirector {
    runner: Arc<dyn CommandRunner>,
    docker_bin: String,
    /// Require staged files to belong to the authenticated service UID.
    service_uid: u32,
    staging_root: PathBuf,
    state_root: PathBuf,
    proc_root: PathBuf,
    installed_trust_root: PathBuf,
    installer_bin: PathBuf,
    dpkg_bin: PathBuf,
    systemctl_bin: PathBuf,
    sparkd_bin: PathBuf,
    privileged_uid: u32,
}

impl RuntimeUpdateDirector {
    pub fn new(service_uid: u32) -> Self {
        Self {
            runner: Arc::new(SystemCommandRunner),
            docker_bin: "docker".to_owned(),
            service_uid,
            staging_root: PathBuf::from(DEFAULT_STAGING_ROOT),
            state_root: PathBuf::from(DEFAULT_STATE_ROOT),
            proc_root: PathBuf::from("/proc"),
            installed_trust_root: PathBuf::from(INSTALLED_TRUST_ROOT),
            installer_bin: PathBuf::from(INSTALLER_BIN),
            dpkg_bin: PathBuf::from(DPKG_BIN),
            systemctl_bin: PathBuf::from(SYSTEMCTL_BIN),
            sparkd_bin: PathBuf::from(SPARKD_BIN),
            privileged_uid: nix::unistd::geteuid().as_raw(),
        }
    }

    pub fn with_runner(mut self, runner: Arc<dyn CommandRunner>) -> Self {
        self.runner = runner;
        self
    }

    pub fn with_service_uid(mut self, service_uid: u32) -> Self {
        self.service_uid = service_uid;
        self
    }

    pub fn with_systemctl_bin(mut self, systemctl_bin: impl Into<PathBuf>) -> Self {
        self.systemctl_bin = systemctl_bin.into();
        self
    }

    #[allow(clippy::too_many_arguments)]
    pub fn with_paths(
        mut self,
        staging_root: impl Into<PathBuf>,
        state_root: impl Into<PathBuf>,
        proc_root: impl Into<PathBuf>,
        installed_trust_root: impl Into<PathBuf>,
        installer_bin: impl Into<PathBuf>,
        dpkg_bin: impl Into<PathBuf>,
        sparkd_bin: impl Into<PathBuf>,
    ) -> Self {
        self.staging_root = staging_root.into();
        self.state_root = state_root.into();
        self.proc_root = proc_root.into();
        self.installed_trust_root = installed_trust_root.into();
        self.installer_bin = installer_bin.into();
        self.dpkg_bin = dpkg_bin.into();
        self.sparkd_bin = sparkd_bin.into();
        self
    }

    /// The only fixed command line the request handler runs (planning mode).
    pub fn planned_argv(
        &self,
        release_id: &str,
    ) -> Result<Vec<(String, Vec<String>)>, UpdateError> {
        self.runtime_commands().planned_argv(release_id)
    }

    fn schedule_argv(&self, release_id: &str) -> (String, Vec<String>) {
        self.runtime_commands().schedule_argv(release_id)
    }

    /// Persist a validated handoff and queue detached work before package installation can stop this request-serving helper.
    pub fn schedule(&self, release_id: &str) -> Result<UpdateOutcome, UpdateError> {
        validate_release_id(release_id)?;
        if self.current_release_id()?.as_deref() == Some(release_id) {
            return Ok(UpdateOutcome::AlreadyCommitted {
                release_id: release_id.to_owned(),
            });
        }

        {
            let _staging_guard = acquire_staging_lock(&self.staging_root, false)?;
            self.validate_staging(&self.staging_root.join(release_id))?;
        }
        self.assert_installed_trust_root()?;
        let created = self.record_scheduled_release(release_id)?;
        if let Err(error) = self.record_update_status(&RuntimeUpdateStatus::Scheduled {
            release_id: release_id.to_owned(),
        }) {
            if created {
                let _ = self.clear_scheduled_release(release_id);
            }
            return Err(error);
        }
        let (program, args) = self.schedule_argv(release_id);
        let output = match self.runner.run(&program, &args) {
            Ok(output) => output,
            Err(error) => {
                if created {
                    let _ = self.clear_scheduled_release(release_id);
                }
                let _ = self.record_update_status(&RuntimeUpdateStatus::Failed {
                    release_id: release_id.to_owned(),
                    code: "UPDATE_SCHEDULE_FAILED".into(),
                });
                return Err(UpdateError::Failure(error));
            }
        };
        if !output.success() {
            if created {
                let _ = self.clear_scheduled_release(release_id);
            }
            let _ = self.record_update_status(&RuntimeUpdateStatus::Failed {
                release_id: release_id.to_owned(),
                code: "UPDATE_SCHEDULE_FAILED".into(),
            });
            return Err(UpdateError::Failure(format!(
                "UPDATE_SCHEDULE_FAILED systemd refused the update worker: {}",
                truncate(&output.stderr_text(), 2000)
            )));
        }
        Ok(UpdateOutcome::Scheduled {
            release_id: release_id.to_owned(),
        })
    }

    /// Accept worker releases only when schedule previously persisted their exact release-ID handoff.
    pub fn apply_scheduled(&self, release_id: &str) -> Result<UpdateOutcome, UpdateError> {
        validate_release_id(release_id)?;
        match self.scheduled_release_id()? {
            Some(scheduled) if scheduled == release_id => {}
            Some(scheduled) => {
                return Err(UpdateError::refused(format!(
                    "UPDATE_NOT_SCHEDULED {release_id} is not the scheduled release ({scheduled})"
                )));
            }
            None => {
                return Err(UpdateError::refused(format!(
                    "UPDATE_NOT_SCHEDULED {release_id} has no root-owned hand-off marker"
                )));
            }
        }

        let result = self.install(release_id);
        let status = match &result {
            Ok(outcome) => RuntimeUpdateStatus::Completed {
                outcome: outcome.clone(),
            },
            Err(error) => RuntimeUpdateStatus::Failed {
                release_id: release_id.to_owned(),
                code: update_failure_code(error),
            },
        };
        let status_result = self.record_update_status(&status);
        if let Err(error) = self.clear_scheduled_release(release_id) {
            tracing::error!(release_id, %error, "failed to clear update hand-off marker");
            if result.is_ok() {
                return Err(error);
            }
        }
        if let Err(error) = status_result {
            tracing::error!(release_id, %error, "failed to persist runtime update outcome");
            if result.is_ok() {
                return Err(error);
            }
        }
        result
    }

    /// Read only root-owned evidence that the service account cannot replace through the protocol.
    pub fn update_status(
        &self,
        release_id: &str,
    ) -> Result<Option<RuntimeUpdateStatus>, UpdateError> {
        self.journal().update_status(release_id)
    }

    /// Apply the worker transaction, ending in commit, verified rollback or explicit manual recovery.
    pub fn install(&self, release_id: &str) -> Result<UpdateOutcome, UpdateError> {
        validate_release_id(release_id)?;

        // A recorded commit makes retries idempotent.
        if self.current_release_id()?.as_deref() == Some(release_id) {
            return Ok(UpdateOutcome::AlreadyCommitted {
                release_id: release_id.to_owned(),
            });
        }

        // Refuse before stopping services while any inference or project workload remains active.
        self.assert_no_active_workloads()?;

        self.assert_installed_trust_root()?;

        // Seal with no-follow opens, then verify that root-owned snapshot to prevent staged-file swaps between checking and copying.
        let seal = self.seal(release_id)?;
        let report = self.run_verifier(
            &seal.directory,
            STAGED_MANIFEST,
            STAGED_PACKAGE,
            STAGED_SIGNATURE,
        )?;
        let Some(sha256) = report.sha256.as_deref() else {
            return Err(UpdateError::refused(
                "UPDATE_VERIFICATION_FAILED verifier report was not parseable",
            ));
        };
        if sha256_file(&seal.package)? != sha256 {
            return Err(UpdateError::refused(
                "UPDATE_STAGING_INVALID sealed package digest does not match the verified manifest",
            ));
        }

        // The detached worker stops both units before dpkg runs preinst, after the request handler has returned.
        self.stop_runtime_services()?;
        if self.sparkd_running()? {
            return Err(UpdateError::refused(
                "UPDATE_NOT_QUIESCENT sparkd is still running after systemd stop",
            ));
        }

        // Use dpkg's exit status to capture migration, startup and health-gate success.
        let apply_result = self.run_apply(&seal.package)?;

        if apply_result.success() {
            self.commit(release_id, &seal.directory)?;
            return Ok(UpdateOutcome::Committed {
                release_id: release_id.to_owned(),
                sha256: report.sha256.unwrap_or_default(),
            });
        }

        tracing::warn!(
            release_id,
            status = ?apply_result.status,
            stderr = %apply_result.stderr_text().trim(),
            "runtime update failed its post-install gate; attempting rollback"
        );
        self.rollback(release_id)
    }

    fn assert_no_active_workloads(&self) -> Result<(), UpdateError> {
        self.runtime_commands().assert_no_active_workloads()
    }

    fn stop_runtime_services(&self) -> Result<(), UpdateError> {
        self.runtime_commands().stop_runtime_services()
    }

    fn sparkd_running(&self) -> Result<bool, UpdateError> {
        self.runtime_commands().sparkd_running()
    }

    fn validate_staging(&self, staged: &Path) -> Result<(), UpdateError> {
        self.staging().validate_staging(staged)
    }

    fn assert_installed_trust_root(&self) -> Result<(), UpdateError> {
        self.staging().assert_installed_trust_root()
    }

    fn run_verifier(
        &self,
        directory: &Path,
        manifest: &str,
        package: &str,
        signature: &str,
    ) -> Result<VerifyReport, UpdateError> {
        self.runtime_commands()
            .run_verifier(directory, manifest, package, signature)
    }

    fn seal(&self, release_id: &str) -> Result<Seal, UpdateError> {
        self.staging().seal(release_id)
    }

    fn copy_sealed(&self, source: &Path, destination: &Path) -> Result<(), UpdateError> {
        self.staging().copy_sealed(source, destination)
    }

    fn run_apply(&self, sealed_package: &Path) -> Result<CommandOutput, UpdateError> {
        self.runtime_commands().run_apply(sealed_package)
    }

    /// Record a successful commit and retain the package that is now current.
    fn commit(&self, release_id: &str, sealed: &Path) -> Result<(), UpdateError> {
        fs::create_dir_all(&self.state_root)?;
        fs::set_permissions(&self.state_root, std::fs::Permissions::from_mode(0o700))?;

        let current = self.state_root.join("current-release-id");
        std::fs::write(&current, format!("{release_id}\n"))?;
        fs::set_permissions(&current, std::fs::Permissions::from_mode(0o600))?;

        let retained = self.state_root.join("retained");
        fs::create_dir_all(&retained)?;
        fs::set_permissions(&retained, std::fs::Permissions::from_mode(0o700))?;
        for (sealed_name, retained_name) in [
            (STAGED_MANIFEST, RETAINED_MANIFEST),
            (STAGED_SIGNATURE, RETAINED_SIGNATURE),
            (STAGED_PACKAGE, RETAINED_PACKAGE),
        ] {
            self.copy_sealed(&sealed.join(sealed_name), &retained.join(retained_name))?;
        }
        Ok(())
    }

    fn record_update_status(&self, status: &RuntimeUpdateStatus) -> Result<(), UpdateError> {
        self.journal().record_update_status(status)
    }

    /// Return true only when creating a new handoff marker, false for a matching retry.
    fn record_scheduled_release(&self, release_id: &str) -> Result<bool, UpdateError> {
        self.journal().record_scheduled_release(release_id)
    }

    fn scheduled_release_id(&self) -> Result<Option<String>, UpdateError> {
        self.journal().scheduled_release_id()
    }

    fn clear_scheduled_release(&self, release_id: &str) -> Result<(), UpdateError> {
        self.journal().clear_scheduled_release(release_id)
    }

    fn current_release_id(&self) -> Result<Option<String>, UpdateError> {
        self.journal().current_release_id()
    }

    /// Reverify and reinstall the retained package or report manual recovery without claiming an unperformed rollback.
    fn rollback(&self, release_id: &str) -> Result<UpdateOutcome, UpdateError> {
        let retained_dir = self.state_root.join("retained");
        let retained_package = retained_dir.join(RETAINED_PACKAGE);

        let retained_present = [RETAINED_PACKAGE, RETAINED_MANIFEST, RETAINED_SIGNATURE]
            .iter()
            .all(|name| {
                fs::symlink_metadata(retained_dir.join(name)).is_ok_and(|meta| meta.is_file())
            });
        if !retained_present {
            let evidence = vec![
                self.staging_root.join(release_id),
                self.state_root.join("apply").join(release_id),
                self.state_root.join("retained"),
            ];
            tracing::error!(
                release_id,
                "update failed and no retained previous package exists; automatic package rollback is not safe"
            );
            return Ok(UpdateOutcome::DataRestoredPackageManual {
                release_id: release_id.to_owned(),
                evidence,
            });
        }

        // Reverify retained packages even though their storage is root-owned.
        let report = self.run_verifier(
            &retained_dir,
            RETAINED_MANIFEST,
            RETAINED_PACKAGE,
            RETAINED_SIGNATURE,
        )?;
        if report.sha256.is_none() {
            return Err(UpdateError::refused(
                "UPDATE_ROLLBACK_FAILED retained package report was not parseable",
            ));
        }

        let rolled_back_to = self
            .current_release_id()?
            .unwrap_or_else(|| "previous".to_owned());
        let result = self.runner.run(
            &self.dpkg_bin.to_string_lossy(),
            &["-i".into(), retained_package.to_string_lossy().into_owned()],
        )?;
        if !result.success() {
            tracing::error!(
                release_id,
                "automatic package rollback also failed: {}",
                truncate(&result.stderr_text(), 2000)
            );
            return Err(UpdateError::refused(format!(
                "UPDATE_ROLLBACK_FAILED rollback install failed: {}",
                truncate(&result.stderr_text(), 2000)
            )));
        }
        Ok(UpdateOutcome::RolledBack {
            release_id: release_id.to_owned(),
            rolled_back_to,
        })
    }
}

#[cfg(test)]
#[path = "update/seal_tests.rs"]
mod seal_tests;

mod journal;

impl RuntimeUpdateDirector {
    fn journal(&self) -> journal::UpdateJournal<'_> {
        journal::UpdateJournal {
            state_root: &self.state_root,
            privileged_uid: self.privileged_uid,
        }
    }
}

mod staging;

impl RuntimeUpdateDirector {
    fn staging(&self) -> staging::StagedRelease<'_> {
        staging::StagedRelease {
            staging_root: &self.staging_root,
            state_root: &self.state_root,
            service_uid: self.service_uid,
            installed_trust_root: &self.installed_trust_root,
        }
    }
}

mod commands;

pub use commands::{
    CommandOutput, CommandRunner, MAX_COMMAND_OUTPUT_BYTES, RecordingRunner, SystemCommandRunner,
};

use commands::{is_zombie, truncate};

mod outcomes;

use outcomes::update_failure_code;

pub use outcomes::{RuntimeUpdateStatus, UpdateError, UpdateOutcome};

mod validation;

pub use validation::validate_release_id;

use validation::{Seal, VerifyReport, sha256_file};

mod runtime_commands;

impl RuntimeUpdateDirector {
    fn runtime_commands(&self) -> runtime_commands::RuntimeCommands<'_> {
        runtime_commands::RuntimeCommands {
            runner: self.runner.as_ref(),
            docker_bin: &self.docker_bin,
            proc_root: &self.proc_root,
            sparkd_bin: &self.sparkd_bin,
            installed_trust_root: &self.installed_trust_root,
            installer_bin: &self.installer_bin,
            systemctl_bin: &self.systemctl_bin,
            dpkg_bin: &self.dpkg_bin,
        }
    }
}

mod policy;
use policy::MAX_UPDATE_STATUS_BYTES;
pub use policy::{
    DEFAULT_STAGING_ROOT, DEFAULT_STATE_ROOT, DPKG_BIN, INSTALLED_TRUST_ROOT, INSTALLER_BIN,
    MAX_MANIFEST_BYTES, MAX_PACKAGE_BYTES, MAX_SIGNATURE_BYTES, MAX_VERIFY_REPORT_BYTES,
    RELEASE_ID_MAX, RELEASE_ID_MIN, RETAINED_MANIFEST, RETAINED_PACKAGE, RETAINED_SIGNATURE,
    SCHEDULED_RELEASE, SPARKD_BIN, STAGED_MANIFEST, STAGED_PACKAGE, STAGED_SIGNATURE,
    SYSTEMCTL_BIN, UPDATE_STATUS_DIRECTORY,
};
