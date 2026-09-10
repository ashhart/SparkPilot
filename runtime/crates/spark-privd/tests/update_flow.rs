//! Exercise signed-update validation, sealing, quiescence, retries and rollback against the production director.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use sha2::Digest as _;
use spark_privd::OpBackend as _;
use spark_privd::update::CommandRunner as _;
use spark_privd::update::{
    CommandOutput, DEFAULT_STAGING_ROOT, MAX_MANIFEST_BYTES, MAX_PACKAGE_BYTES,
    MAX_SIGNATURE_BYTES, RETAINED_MANIFEST, RETAINED_PACKAGE, RETAINED_SIGNATURE, RecordingRunner,
    RuntimeUpdateDirector, RuntimeUpdateStatus, STAGED_MANIFEST, STAGED_PACKAGE, STAGED_SIGNATURE,
    UpdateOutcome, validate_release_id,
};

/// Match the expected service UID to the account creating staged test files.
fn euid() -> u32 {
    unsafe { libc::geteuid() }
}

fn sha256(bytes: &[u8]) -> String {
    hex::encode(sha2::Sha256::digest(bytes))
}

struct Harness {
    dir: tempfile::TempDir,
    staging: PathBuf,
    state: PathBuf,
    proc: PathBuf,
    trust: PathBuf,
    installer: PathBuf,
    dpkg: PathBuf,
    sparkd: PathBuf,
    runner: Arc<RecordingRunner>,
}

impl Harness {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let staging = dir.path().join("updates");
        let state = dir.path().join("state");
        let proc = dir.path().join("proc");
        let trust = dir.path().join("trust/release-keys.json");
        fs::create_dir_all(trust.parent().unwrap()).unwrap();
        fs::write(&trust, b"{}").unwrap();
        fs::set_permissions(&trust, fs::Permissions::from_mode(0o644)).unwrap();
        let runner = Arc::new(RecordingRunner::new());
        Self {
            dir,
            staging,
            state,
            proc,
            trust,
            installer: PathBuf::from("/usr/lib/spark-runtime/spark-installer"),
            dpkg: PathBuf::from("/usr/bin/dpkg"),
            sparkd: PathBuf::from("/usr/lib/spark-runtime/sparkd"),
            runner,
        }
    }

    fn director(&self) -> RuntimeUpdateDirector {
        RuntimeUpdateDirector::new(euid())
            .with_runner(self.runner.clone())
            .with_paths(
                &self.staging,
                &self.state,
                &self.proc,
                &self.trust,
                &self.installer,
                &self.dpkg,
                &self.sparkd,
            )
    }

    /// Stage the three fixed release files as the test service account.
    fn stage(&self, release_id: &str, package: &[u8]) -> PathBuf {
        let staged = self.staging.join(release_id);
        fs::create_dir_all(&staged).unwrap();
        fs::write(staged.join(STAGED_MANIFEST), b"{}").unwrap();
        fs::write(staged.join(STAGED_PACKAGE), package).unwrap();
        fs::write(staged.join(STAGED_SIGNATURE), b"sig").unwrap();
        fs::set_permissions(&staged, fs::Permissions::from_mode(0o750)).unwrap();
        staged
    }

    /// Return a verifier digest matching staged package bytes so seal verification can pass.
    fn verify_report(&self, staged: &Path) -> String {
        let digest = sha256(&fs::read(staged.join(STAGED_PACKAGE)).unwrap());
        serde_json::json!({
            "name": "package",
            "size": fs::metadata(staged.join(STAGED_PACKAGE)).unwrap().len(),
            "sha256": digest,
            "signature_key_id": "test",
            "trust_root_source": "installed",
        })
        .to_string()
    }
}

fn assert_refused<T: std::fmt::Debug>(
    result: Result<T, spark_privd::update::UpdateError>,
    needle: &str,
) {
    let error = result.unwrap_err();
    assert!(
        error.to_string().contains(needle),
        "expected {needle:?} in {error:?}"
    );
}

include!("update_flow/scenarios/release_id_is_a_single_safe_component.rs");

include!("update_flow/scenarios/privileged_request_only_schedules_the_detached_worker.rs");

include!("update_flow/scenarios/backend_returns_after_systemd_handoff_before_verifier_or_dpkg.rs");

include!("update_flow/scenarios/worker_requires_handoff_and_clears_it_after_success.rs");

include!("update_flow/scenarios/detached_update_status_survives_director_restart.rs");

include!("update_flow/scenarios/service_stop_failure_never_reaches_dpkg.rs");

include!("update_flow/scenarios/scheduling_failure_removes_the_new_handoff_marker.rs");

include!("update_flow/scenarios/invalid_outcome_directory_never_leaves_an_unscheduled_handoff.rs");

include!("update_flow/scenarios/another_release_cannot_replace_an_active_handoff.rs");

include!("update_flow/scenarios/worker_failure_clears_the_handoff_for_a_safe_retry.rs");

include!("update_flow/scenarios/successful_apply_seals_commits_and_retains.rs");

include!("update_flow/scenarios/retry_of_current_release_is_an_idempotent_no_op.rs");

include!("update_flow/scenarios/verification_failure_refuses_before_dpkg.rs");

include!("update_flow/scenarios/malformed_verifier_report_is_refused.rs");

include!("update_flow/scenarios/quiescence_refuses_when_containers_are_running.rs");

include!("update_flow/scenarios/quiescence_refuses_when_sparkd_daemon_is_live.rs");

include!("update_flow/scenarios/zombies_do_not_block_quiescence.rs");

include!("update_flow/scenarios/symlinked_staged_package_is_refused.rs");

include!("update_flow/scenarios/missing_staged_file_is_refused.rs");

include!("update_flow/scenarios/oversized_staged_files_are_refused.rs");

include!("update_flow/scenarios/staging_owned_by_another_uid_is_refused.rs");

include!("update_flow/scenarios/world_writable_staging_is_refused.rs");

include!("update_flow/scenarios/missing_installed_trust_root_is_refused.rs");

include!("update_flow/scenarios/sealed_digest_mismatch_is_refused.rs");

include!("update_flow/scenarios/failed_install_rolls_back_to_the_retained_package.rs");

include!("update_flow/scenarios/no_retained_package_fails_closed_without_claiming_rollback.rs");

include!("update_flow/scenarios/rollback_failure_is_reported_fail_closed.rs");

include!(
    "update_flow/scenarios/a_different_release_id_is_not_short_circuited_by_a_prior_commit.rs"
);

include!("update_flow/scenarios/staged_names_are_always_the_fixed_three.rs");

include!("update_flow/scenarios/runner_command_output_is_capped_by_the_system_runner_bound.rs");

include!("update_flow/scenarios/plan_only_mode_reports_planned_argv_through_the_backend.rs");

include!("update_flow/scenarios/on_darwin_or_linux_proc_scan_ignores_non_numeric_entries.rs");
