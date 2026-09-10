//! Own container-bound terminal children while the daemon pumps their PTY descriptors; see docs/development/privileged-boundaries.md.

use std::collections::HashMap;
use std::ffi::CString;
use std::os::fd::{AsRawFd, OwnedFd};
use std::process::Command;

use nix::pty::OpenptyResult;
use nix::sys::signal::Signal;
use nix::unistd::{ForkResult, Pid};
use parking_lot::Mutex;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::backend::BackendError;
use crate::protocol::{TerminalShell, valid_project_container_id};

/// Bound terminal dimensions independently of host allocations.
pub const MAX_COLUMNS: u16 = 1000;
pub const MAX_ROWS: u16 = 1000;
/// How long a closing session may take to exit before it is killed.
const CLOSE_GRACE: std::time::Duration = std::time::Duration::from_millis(1500);
/// The only search path a docker child gets; the helper's own environment is never inherited.
const CHILD_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

/// Build the docker child's whole environment: a fixed PATH and TERM plus the unit's DOCKER_CONFIG, nothing else.
pub(crate) fn child_environment(
    inherited: impl Iterator<Item = (String, String)>,
) -> Vec<(String, String)> {
    let mut environment = vec![
        ("PATH".to_owned(), CHILD_PATH.to_owned()),
        ("TERM".to_owned(), "xterm-256color".to_owned()),
    ];
    environment.extend(inherited.filter(|(name, _)| name == "DOCKER_CONFIG"));
    environment
}

/// Find the docker binary on the fixed child PATH in the parent, so the child needs no search of its own.
fn resolve_program(program: &str) -> Option<std::path::PathBuf> {
    use std::os::unix::fs::PermissionsExt as _;
    if program.contains('/') {
        return Some(std::path::PathBuf::from(program));
    }
    CHILD_PATH
        .split(':')
        .map(|directory| std::path::Path::new(directory).join(program))
        .find(|candidate| {
            std::fs::metadata(candidate).is_ok_and(|metadata| {
                metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
            })
        })
}

#[derive(Debug)]
struct Session {
    pid: Pid,
    project_id: Uuid,
    container_id: String,
    development: bool,
}

/// Owns every interactive session this helper has opened.
#[derive(Debug)]
pub struct TerminalDirector {
    docker_bin: String,
    sessions: Mutex<HashMap<Uuid, Session>>,
}

impl TerminalDirector {
    pub fn new(docker_bin: impl Into<String>) -> Self {
        Self {
            docker_bin: docker_bin.into(),
            sessions: Mutex::new(HashMap::new()),
        }
    }

    /// Use fixed shell arguments in /workspace and set TERM explicitly without inheriting the helper environment.
    pub fn argv(&self, container_id: &str, shell: TerminalShell) -> Vec<String> {
        let mut argv = vec![
            self.docker_bin.clone(),
            "exec".into(),
            "--interactive".into(),
            "--tty".into(),
            "--workdir=/workspace".into(),
            "--env=TERM=xterm-256color".into(),
            container_id.to_owned(),
        ];
        argv.extend(shell.argv().iter().map(|part| (*part).to_owned()));
        argv
    }

    /// Is the named project container running right now?
    fn container_is_running(&self, container_id: &str) -> Result<bool, BackendError> {
        let output = Command::new(&self.docker_bin)
            .env_clear()
            .envs(child_environment(std::env::vars()))
            .arg("inspect")
            .arg("--format={{.State.Running}}")
            .arg(container_id)
            .output()
            .map_err(|error| BackendError::Failure(format!("docker inspect: {error}")))?;
        if !output.status.success() {
            return Ok(false);
        }
        Ok(String::from_utf8_lossy(&output.stdout).trim() == "true")
    }

    /// Open one session and return its pseudo-terminal master.
    pub fn open(
        &self,
        project_id: Uuid,
        terminal_id: Uuid,
        container_id: &str,
        shell: TerminalShell,
        columns: u16,
        rows: u16,
    ) -> Result<(OwnedFd, Value), BackendError> {
        if !valid_project_container_id(container_id) {
            return Err(BackendError::InvalidInput(
                "terminals may only be opened in a spark-project-<uuid> container".into(),
            ));
        }
        if columns == 0 || rows == 0 || columns > MAX_COLUMNS || rows > MAX_ROWS {
            return Err(BackendError::InvalidInput(
                "terminal window size is outside the supported range".into(),
            ));
        }
        if self.sessions.lock().contains_key(&terminal_id) {
            return Err(BackendError::InvalidInput(
                "a session already exists for this terminal id".into(),
            ));
        }
        // Verify project ownership before allocating the PTY or starting docker exec.
        crate::project_tools::validate_container(
            &self.docker_bin,
            false,
            container_id,
            &project_id,
        )?;
        if !self.container_is_running(container_id)? {
            return Err(BackendError::Failure(format!(
                "project container {container_id} is not running"
            )));
        }

        let mut argv = self.argv(container_id, shell);
        if shell == TerminalShell::Development {
            argv.insert(6, format!("--env=SPARK_TERMINAL_ID={terminal_id}"));
        }
        let program = resolve_program(&argv[0])
            .and_then(|path| CString::new(path.into_os_string().into_encoded_bytes()).ok())
            .ok_or_else(|| {
                BackendError::Failure("container runtime binary is unavailable".into())
            })?;
        let environment = child_environment(std::env::vars())
            .into_iter()
            .map(|(name, value)| CString::new(format!("{name}={value}")))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BackendError::InvalidInput("terminal environment is invalid".into()))?;
        let arguments = argv
            .iter()
            .map(|part| CString::new(part.as_str()))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BackendError::InvalidInput("terminal argv is invalid".into()))?;

        let winsize = nix::pty::Winsize {
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let OpenptyResult { master, slave } = nix::pty::openpty(Some(&winsize), None)
            .map_err(|errno| BackendError::Failure(format!("openpty: {errno}")))?;

        // SAFETY: the forked child calls only async-signal-safe functions before execv.
        match unsafe { nix::unistd::fork() } {
            Ok(ForkResult::Parent { child }) => {
                drop(slave);
                self.sessions.lock().insert(
                    terminal_id,
                    Session {
                        pid: child,
                        project_id,
                        container_id: container_id.to_owned(),
                        development: shell == TerminalShell::Development,
                    },
                );
                let summary = json!({
                    "terminal_id": terminal_id,
                    "project_id": project_id,
                    "container_id": container_id,
                    "shell": shell.name(),
                    "columns": columns,
                    "rows": rows,
                    "runs_on_host": false,
                });
                Ok((master, summary))
            }
            Ok(ForkResult::Child) => {
                let slave_fd = slave.as_raw_fd();
                unsafe {
                    if libc::setsid() < 0 {
                        libc::_exit(126);
                    }
                    // Set the controlling terminal for job control and SIGWINCH forwarding.
                    libc::ioctl(slave_fd, libc::TIOCSCTTY as _, 0);
                    for target in [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO] {
                        if libc::dup2(slave_fd, target) < 0 {
                            libc::_exit(126);
                        }
                    }
                    if slave_fd > libc::STDERR_FILENO {
                        libc::close(slave_fd);
                    }
                    libc::close(master.as_raw_fd());
                    let mut pointers: Vec<*const libc::c_char> =
                        arguments.iter().map(|part| part.as_ptr()).collect();
                    pointers.push(std::ptr::null());
                    let mut environment_pointers: Vec<*const libc::c_char> =
                        environment.iter().map(|entry| entry.as_ptr()).collect();
                    environment_pointers.push(std::ptr::null());
                    // execve with the scrubbed environment: no helper variable or search path reaches docker.
                    libc::execve(
                        program.as_ptr(),
                        pointers.as_ptr(),
                        environment_pointers.as_ptr(),
                    );
                    libc::_exit(127);
                }
            }
            Err(errno) => Err(BackendError::Failure(format!("fork: {errno}"))),
        }
    }

    /// Terminate and reap one session.
    pub fn close(&self, terminal_id: Uuid) -> Result<Value, BackendError> {
        let Some(session) = self.sessions.lock().remove(&terminal_id) else {
            return Err(BackendError::InvalidInput(
                "no such interactive session".into(),
            ));
        };
        // Disconnecting docker exec does not stop its container-side agent.
        if session.development {
            let stopped = self.stop_development_processes(&session.container_id, terminal_id);
            if let Err(error) = stopped {
                self.sessions.lock().insert(terminal_id, session);
                return Err(error);
            }
        }
        // Reap the host-side Docker client after the container-side session has stopped.
        let _ = nix::sys::signal::kill(session.pid, Signal::SIGHUP);
        let deadline = std::time::Instant::now() + CLOSE_GRACE;
        let mut reaped = false;
        while std::time::Instant::now() < deadline {
            match nix::sys::wait::waitpid(session.pid, Some(nix::sys::wait::WaitPidFlag::WNOHANG)) {
                Ok(nix::sys::wait::WaitStatus::StillAlive) => {
                    std::thread::sleep(std::time::Duration::from_millis(20));
                }
                Ok(_) | Err(nix::errno::Errno::ECHILD) => {
                    reaped = true;
                    break;
                }
                Err(_) => break,
            }
        }
        if !reaped {
            let _ = nix::sys::signal::kill(session.pid, Signal::SIGKILL);
            let _ = nix::sys::wait::waitpid(session.pid, None);
        }
        Ok(json!({
            "terminal_id": terminal_id,
            "project_id": session.project_id,
            "container_id": session.container_id,
            "escalated": !reaped,
        }))
    }

    fn stop_development_processes(
        &self,
        container_id: &str,
        terminal_id: Uuid,
    ) -> Result<(), BackendError> {
        if !self.container_is_running(container_id)? {
            return Ok(());
        }
        let output = Command::new(&self.docker_bin)
            .env_clear()
            .envs(child_environment(std::env::vars()))
            .args([
                "exec",
                container_id,
                "node",
                "-e",
                include_str!("terminal_stop.cjs"),
                "--",
                "spark-stop",
                &terminal_id.to_string(),
            ])
            .output()
            .map_err(|error| BackendError::Failure(format!("session termination: {error}")))?;
        if !output.status.success() {
            return Err(BackendError::Failure(
                "The container could not confirm session termination.".into(),
            ));
        }
        Ok(())
    }

    /// Reap exited children opportunistically to avoid zombies in the long-lived helper.
    pub fn reap_exited(&self) {
        let mut sessions = self.sessions.lock();
        sessions.retain(|_, session| {
            !matches!(
                nix::sys::wait::waitpid(session.pid, Some(nix::sys::wait::WaitPidFlag::WNOHANG)),
                Ok(nix::sys::wait::WaitStatus::Exited(_, _))
                    | Ok(nix::sys::wait::WaitStatus::Signaled(_, _, _))
                    | Err(nix::errno::Errno::ECHILD)
            )
        });
    }

    /// Number of live sessions (diagnostics and tests).
    pub fn live_sessions(&self) -> usize {
        self.sessions.lock().len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn argv_is_a_container_exec_with_a_constant_shell() {
        let director = TerminalDirector::new("docker");
        let container = format!("spark-project-{}", Uuid::new_v4());
        let argv = director.argv(&container, TerminalShell::Login);
        assert_eq!(
            argv,
            vec![
                "docker".to_owned(),
                "exec".into(),
                "--interactive".into(),
                "--tty".into(),
                "--workdir=/workspace".into(),
                "--env=TERM=xterm-256color".into(),
                container.clone(),
                "/bin/sh".into(),
                "-l".into(),
            ]
        );
        // Nothing in the argv can be influenced into a host command.
        assert!(argv.iter().all(|part| !part.contains("..")));
        assert_eq!(
            director.argv(&container, TerminalShell::Python).last(),
            Some(&"-i".to_owned())
        );
    }

    /// Whatever the helper was started with, the docker child sees only the fixed PATH, TERM and the unit's DOCKER_CONFIG.
    #[test]
    fn the_docker_child_environment_is_scrubbed_to_an_allowlist() {
        let inherited = [
            ("PATH", "/tmp/evil:/usr/bin"),
            ("LD_PRELOAD", "/tmp/evil.so"),
            ("DOCKER_HOST", "tcp://198.51.100.1:2375"),
            ("DOCKER_CONFIG", "/var/lib/spark-privd/docker"),
            ("HOME", "/root"),
            ("TERM", "dumb"),
        ]
        .into_iter()
        .map(|(name, value)| (name.to_owned(), value.to_owned()));
        assert_eq!(
            child_environment(inherited),
            vec![
                ("PATH".to_owned(), CHILD_PATH.to_owned()),
                ("TERM".to_owned(), "xterm-256color".to_owned()),
                (
                    "DOCKER_CONFIG".to_owned(),
                    "/var/lib/spark-privd/docker".to_owned()
                ),
            ]
        );
        assert_eq!(child_environment(std::iter::empty()).len(), 2);
    }

    #[test]
    fn the_container_runtime_is_resolved_on_the_fixed_path_only() {
        assert_eq!(
            resolve_program("/opt/docker/bin/docker"),
            Some(std::path::PathBuf::from("/opt/docker/bin/docker"))
        );
        assert!(resolve_program("spark-no-such-binary").is_none());
        let shell = resolve_program("sh").expect("sh is on every fixed path");
        assert!(shell.is_absolute() && shell.ends_with("sh"));
    }

    #[test]
    fn only_this_runtimes_project_containers_are_addressable() {
        assert!(valid_project_container_id(&format!(
            "spark-project-{}",
            Uuid::new_v4()
        )));
        for value in [
            "spark-model-1",
            "spark-project-",
            "spark-project-not-a-uuid",
            "../etc",
            "",
            "postgres",
        ] {
            assert!(!valid_project_container_id(value), "accepted {value:?}");
        }
    }

    #[test]
    fn opening_outside_a_project_container_is_refused_before_any_exec() {
        let director = TerminalDirector::new("/nonexistent/docker");
        let error = director
            .open(
                Uuid::new_v4(),
                Uuid::new_v4(),
                "postgres",
                TerminalShell::Login,
                80,
                24,
            )
            .unwrap_err();
        assert!(matches!(error, BackendError::InvalidInput(_)), "{error}");
        assert_eq!(director.live_sessions(), 0);
    }

    #[test]
    fn window_sizes_are_bounded() {
        let director = TerminalDirector::new("/nonexistent/docker");
        let container = format!("spark-project-{}", Uuid::new_v4());
        for (columns, rows) in [(0, 24), (80, 0), (MAX_COLUMNS + 1, 24), (80, MAX_ROWS + 1)] {
            let error = director
                .open(
                    Uuid::new_v4(),
                    Uuid::new_v4(),
                    &container,
                    TerminalShell::Login,
                    columns,
                    rows,
                )
                .unwrap_err();
            assert!(
                matches!(error, BackendError::InvalidInput(_)),
                "{columns}x{rows} was not rejected"
            );
        }
    }

    #[test]
    fn closing_an_unknown_session_is_an_error_not_a_silent_success() {
        let director = TerminalDirector::new("docker");
        assert!(director.close(Uuid::new_v4()).is_err());
    }
}
