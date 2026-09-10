//! Run detached root OS updates without widening privd's sandbox; download before apply, verify consistency and record each outcome.

use std::fs;
use std::io::Write as _;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use spark_privd::backend::{APT_GET_BIN, FWUPDMGR_BIN};
use spark_privd::update::CommandRunner;

/// Where outcomes live; the helper reads them from the same place.
pub const DEFAULT_STATE_ROOT: &str = spark_privd::backend::SYSTEM_UPDATE_STATE_ROOT;

/// How much of a step's stderr the outcome keeps.
const STDERR_TAIL_BYTES: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SystemUpdateState {
    Running,
    Succeeded,
    Failed,
}

/// One command the worker ran, with what it returned.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StepRecord {
    pub program: String,
    pub args: Vec<String>,
    pub status: Option<i32>,
    pub stderr_tail: String,
}

/// Which step stopped the run, and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StepFailure {
    pub step: usize,
    pub message: String,
}

/// Persist the latest complete outcome after every step for status readers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SystemUpdateOutcome {
    pub job_id: String,
    pub state: SystemUpdateState,
    pub system_packages: bool,
    pub firmware: bool,
    pub started_at_unix: u64,
    pub finished_at_unix: Option<u64>,
    pub steps_planned: usize,
    pub steps: Vec<StepRecord>,
    pub failure: Option<StepFailure>,
}

impl SystemUpdateOutcome {
    pub fn succeeded(&self) -> bool {
        self.state == SystemUpdateState::Succeeded
    }
}

/// A planned command and the exit statuses that count as success.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlannedStep {
    pub program: &'static str,
    pub args: Vec<&'static str>,
    pub accepted_statuses: &'static [i32],
}

/// Plan selected package/firmware steps; fwupdmgr exit 2 means no work and counts as success.
pub fn plan(system_packages: bool, firmware: bool) -> Vec<PlannedStep> {
    let mut steps = Vec::new();
    if system_packages {
        steps.push(PlannedStep {
            program: APT_GET_BIN,
            args: vec!["update"],
            accepted_statuses: &[0],
        });
        steps.push(PlannedStep {
            program: APT_GET_BIN,
            args: vec!["--download-only", "-y", "dist-upgrade"],
            accepted_statuses: &[0],
        });
        steps.push(PlannedStep {
            program: APT_GET_BIN,
            args: vec!["-y", "dist-upgrade"],
            accepted_statuses: &[0],
        });
        steps.push(PlannedStep {
            program: APT_GET_BIN,
            args: vec!["check"],
            accepted_statuses: &[0],
        });
    }
    if firmware {
        steps.push(PlannedStep {
            program: FWUPDMGR_BIN,
            args: vec!["update", "-y"],
            accepted_statuses: &[0, 2],
        });
        steps.push(PlannedStep {
            program: FWUPDMGR_BIN,
            args: vec!["get-devices", "--json"],
            accepted_statuses: &[0],
        });
    }
    steps
}

/// Record every step; return failed-step outcomes normally and reserve errors for inability to record the outcome.
pub fn run(
    job_id: &str,
    system_packages: bool,
    firmware: bool,
    runner: &dyn CommandRunner,
    state_root: &Path,
) -> Result<SystemUpdateOutcome, String> {
    if uuid::Uuid::parse_str(job_id).is_err() {
        return Err("OS update job id must be a UUID".into());
    }
    if !system_packages && !firmware {
        return Err("select at least one update class".into());
    }
    let steps = plan(system_packages, firmware);
    let mut outcome = SystemUpdateOutcome {
        job_id: job_id.to_owned(),
        state: SystemUpdateState::Running,
        system_packages,
        firmware,
        started_at_unix: unix_now(),
        finished_at_unix: None,
        steps_planned: steps.len(),
        steps: Vec::new(),
        failure: None,
    };
    record(state_root, &outcome)?;
    for (index, step) in steps.iter().enumerate() {
        let args: Vec<String> = step.args.iter().map(|arg| (*arg).to_owned()).collect();
        let result = runner.run(step.program, &args);
        let (status, stderr_tail, spawn_error) = match &result {
            Ok(output) => (output.status, tail(&output.stderr), None),
            Err(error) => (None, String::new(), Some(error.clone())),
        };
        outcome.steps.push(StepRecord {
            program: step.program.to_owned(),
            args: args.clone(),
            status,
            stderr_tail: stderr_tail.clone(),
        });
        let accepted = status.is_some_and(|code| step.accepted_statuses.contains(&code));
        if !accepted {
            let message = match (spawn_error, status) {
                (Some(error), _) => format!("{} could not be run: {error}", step.program),
                (None, Some(code)) => format!(
                    "{} {} exited with status {code}: {}",
                    step.program,
                    args.join(" "),
                    stderr_tail.trim()
                ),
                (None, None) => {
                    format!("{} {} was killed by a signal", step.program, args.join(" "))
                }
            };
            outcome.state = SystemUpdateState::Failed;
            outcome.failure = Some(StepFailure {
                step: index,
                message,
            });
            outcome.finished_at_unix = Some(unix_now());
            record(state_root, &outcome)?;
            return Ok(outcome);
        }
        record(state_root, &outcome)?;
    }
    outcome.state = SystemUpdateState::Succeeded;
    outcome.finished_at_unix = Some(unix_now());
    record(state_root, &outcome)?;
    Ok(outcome)
}

/// Atomically publish outcomes in a 0700 directory with 0600 files so the helper never reads partial state.
fn record(state_root: &Path, outcome: &SystemUpdateOutcome) -> Result<(), String> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    fs::create_dir_all(state_root)
        .map_err(|error| format!("could not create {}: {error}", state_root.display()))?;
    fs::set_permissions(state_root, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("could not protect {}: {error}", state_root.display()))?;
    let destination = state_root.join(format!("{}.json", outcome.job_id));
    let temporary = state_root.join(format!(".{}.json.part", outcome.job_id));
    let bytes = serde_json::to_vec(outcome).map_err(|error| error.to_string())?;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|error| format!("could not write {}: {error}", temporary.display()))?;
    file.write_all(&bytes)
        .and_then(|_| file.sync_all())
        .map_err(|error| format!("could not write {}: {error}", temporary.display()))?;
    drop(file);
    fs::rename(&temporary, &destination)
        .map_err(|error| format!("could not publish {}: {error}", destination.display()))
}

fn tail(bytes: &[u8]) -> String {
    let start = bytes.len().saturating_sub(STDERR_TAIL_BYTES);
    String::from_utf8_lossy(&bytes[start..]).into_owned()
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use spark_privd::update::RecordingRunner;
    use std::os::unix::fs::PermissionsExt;

    const JOB: &str = "6f2f6a2e-2a5c-4a4e-9c48-4c7d0a3a1b2c";

    fn read_back(root: &Path) -> SystemUpdateOutcome {
        let bytes = fs::read(root.join(format!("{JOB}.json"))).unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    #[test]
    fn a_clean_package_run_records_every_step_and_succeeds() {
        let root = tempfile::tempdir().unwrap();
        let runner = RecordingRunner::new();
        for _ in 0..4 {
            runner.ok(Some(0), "", "");
        }

        let outcome = run(JOB, true, false, &runner, root.path()).unwrap();

        assert_eq!(outcome.state, SystemUpdateState::Succeeded);
        assert_eq!(outcome.steps.len(), 4);
        assert_eq!(outcome.steps_planned, 4);
        assert!(outcome.failure.is_none());
        assert!(outcome.finished_at_unix.is_some());
        assert_eq!(
            runner
                .calls()
                .into_iter()
                .map(|(program, args)| (program, args.join(" ")))
                .collect::<Vec<_>>(),
            vec![
                (APT_GET_BIN.into(), "update".into()),
                (APT_GET_BIN.into(), "--download-only -y dist-upgrade".into()),
                (APT_GET_BIN.into(), "-y dist-upgrade".into()),
                (APT_GET_BIN.into(), "check".into()),
            ]
        );
        assert_eq!(read_back(root.path()), outcome);
        let mode = fs::metadata(root.path().join(format!("{JOB}.json")))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600, "the outcome is private");
        assert_eq!(
            fs::metadata(root.path()).unwrap().permissions().mode() & 0o777,
            0o700
        );
    }

    #[test]
    fn a_failed_upgrade_stops_the_run_and_keeps_the_reason() {
        let root = tempfile::tempdir().unwrap();
        let runner = RecordingRunner::new();
        runner.ok(Some(0), "", "");
        runner.ok(Some(0), "", "");
        runner.ok(
            Some(100),
            "",
            "E: Sub-process /usr/bin/dpkg returned an error code (1)",
        );

        let outcome = run(JOB, true, true, &runner, root.path()).unwrap();

        assert_eq!(outcome.state, SystemUpdateState::Failed);
        assert_eq!(outcome.steps.len(), 3, "nothing runs after the failed step");
        assert_eq!(outcome.steps_planned, 6);
        let failure = outcome.failure.clone().expect("failure recorded");
        assert_eq!(failure.step, 2);
        assert!(
            failure.message.contains("status 100"),
            "{}",
            failure.message
        );
        assert!(
            failure.message.contains("dpkg returned"),
            "{}",
            failure.message
        );
        assert_eq!(runner.calls().len(), 3);
        assert_eq!(read_back(root.path()), outcome);
    }

    #[test]
    fn firmware_with_nothing_to_do_is_a_success() {
        let root = tempfile::tempdir().unwrap();
        let runner = RecordingRunner::new();
        runner.ok(Some(2), "", "");
        runner.ok(Some(0), "[]", "");

        let outcome = run(JOB, false, true, &runner, root.path()).unwrap();

        assert_eq!(outcome.state, SystemUpdateState::Succeeded);
        assert_eq!(outcome.steps[0].program, FWUPDMGR_BIN);
        assert_eq!(outcome.steps[0].status, Some(2));
    }

    #[test]
    fn the_worker_refuses_a_malformed_job_and_an_empty_selection() {
        let root = tempfile::tempdir().unwrap();
        let runner = RecordingRunner::new();
        assert!(run("../escape", true, false, &runner, root.path()).is_err());
        assert!(run(JOB, false, false, &runner, root.path()).is_err());
        assert!(runner.calls().is_empty());
        assert!(fs::read_dir(root.path()).unwrap().next().is_none());
    }
}
