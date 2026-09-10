//! Manage container PTY descriptors, bounded I/O and typed resize/close; host execution is a nondefault development feature only.

use std::io;
use std::os::fd::{AsFd, AsRawFd, OwnedFd};

use nix::unistd::Pid;
use thiserror::Error;
use uuid::Uuid;

pub use spark_privd::protocol::TerminalShell;

#[derive(Debug, Error)]
pub enum PtyError {
    #[error("PTY open failed: {0}")]
    Open(#[from] nix::errno::Errno),
    #[error("PTY I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("spawn: {0}")]
    Spawn(String),
    #[error("closed")]
    Closed,
}

/// Keep executable selection at the privileged TerminalShell boundary; spawn requests contain no command field.
#[derive(Debug, Clone)]
pub struct PtySpawnRequest {
    /// The project the session belongs to.
    pub project_id: Uuid,
    /// Share the terminal id with the privileged helper for explicit session closure.
    pub terminal_id: Uuid,
    /// The container this session must run inside.
    pub container_id: String,
    pub shell: TerminalShell,
    pub columns: u16,
    pub rows: u16,
}

/// One interactive session: bounded writes, non-blocking reads, typed resize.
pub trait PtySession: Send {
    fn write(&mut self, data: &[u8]) -> Result<(), PtyError>;
    /// Read currently available output within the frame budget, returning empty when nothing is pending.
    fn read(&mut self) -> Result<Vec<u8>, PtyError>;
    fn resize(&mut self, columns: u16, rows: u16) -> Result<(), PtyError>;
    fn close(&mut self);
    fn child_pid(&self) -> Option<Pid>;
}

/// PTY factory boundary.
pub trait PtyRunner: Send + Sync {
    fn spawn(&self, request: &PtySpawnRequest) -> Result<Box<dyn PtySession>, PtyError>;
    /// Release runner-side resources, including privileged children, after dropping the session descriptor.
    fn close(&self, terminal_id: Uuid) -> Result<(), PtyError>;
}

/// Own the PTY master while the runner owns the far-side process, inside the project container in production.
#[derive(Debug)]
pub struct FdPtySession {
    master: Option<OwnedFd>,
}

impl FdPtySession {
    pub fn new(master: OwnedFd) -> Self {
        Self {
            master: Some(master),
        }
    }

    fn descriptor(&self) -> Result<&OwnedFd, PtyError> {
        self.master.as_ref().ok_or(PtyError::Closed)
    }
}

impl PtySession for FdPtySession {
    fn write(&mut self, data: &[u8]) -> Result<(), PtyError> {
        let master = self.descriptor()?;
        let mut written = 0usize;
        while written < data.len() {
            match nix::unistd::write(master, &data[written..]) {
                Ok(0) => return Err(PtyError::Closed),
                Ok(count) => written += count,
                Err(nix::errno::Errno::EINTR) => continue,
                Err(errno) => return Err(PtyError::Open(errno)),
            }
        }
        Ok(())
    }

    fn read(&mut self) -> Result<Vec<u8>, PtyError> {
        let master = self.descriptor()?;
        let mut buffer = [0u8; 8192];
        let mut poll_fds = [nix::poll::PollFd::new(
            master.as_fd(),
            nix::poll::PollFlags::POLLIN,
        )];
        let timeout = nix::poll::PollTimeout::try_from(std::time::Duration::from_millis(100))
            .unwrap_or(nix::poll::PollTimeout::NONE);
        match nix::poll::poll(&mut poll_fds, timeout) {
            Ok(0) => return Ok(Vec::new()),
            Ok(_) => {}
            Err(nix::errno::Errno::EINTR) => return Ok(Vec::new()),
            Err(errno) => return Err(PtyError::Open(errno)),
        }
        let length = unsafe {
            nix::libc::read(
                master.as_raw_fd(),
                buffer.as_mut_ptr() as *mut nix::libc::c_void,
                buffer.len(),
            )
        };
        if length < 0 {
            let errno = nix::errno::Errno::last();
            if errno == nix::errno::Errno::EAGAIN {
                return Ok(Vec::new());
            }
            if errno == nix::errno::Errno::EIO {
                return Err(PtyError::Closed);
            }
            return Err(PtyError::Io(io::Error::from_raw_os_error(errno as i32)));
        }
        if length == 0 {
            return Err(PtyError::Closed);
        }
        Ok(buffer[..length as usize].to_vec())
    }

    fn resize(&mut self, columns: u16, rows: u16) -> Result<(), PtyError> {
        let master = self.descriptor()?;
        let mut size = nix::libc::winsize {
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let result = unsafe {
            nix::libc::ioctl(
                master.as_raw_fd(),
                nix::libc::TIOCSWINSZ,
                &mut size as *mut nix::libc::winsize,
            )
        };
        if result < 0 {
            return Err(PtyError::Open(nix::errno::Errno::last()));
        }
        Ok(())
    }

    fn close(&mut self) {
        self.master = None;
    }

    fn child_pid(&self) -> Option<Pid> {
        // The child belongs to the privileged helper, not to this process.
        None
    }
}

/// Expose host shell execution only under the nondefault host-pty development feature; production never constructs it.
#[cfg(feature = "host-pty")]
pub use host::NativePtyRunner;

#[cfg(feature = "host-pty")]
mod host {
    use super::*;
    use nix::pty::OpenptyResult;
    use nix::unistd::ForkResult;

    /// Run the selected shell on the host only with the development host-pty feature.
    #[derive(Debug, Default)]
    pub struct NativePtyRunner {
        working_directory: std::path::PathBuf,
    }

    impl NativePtyRunner {
        pub fn new(working_directory: impl Into<std::path::PathBuf>) -> Self {
            Self {
                working_directory: working_directory.into(),
            }
        }
    }

    impl PtyRunner for NativePtyRunner {
        fn spawn(&self, request: &PtySpawnRequest) -> Result<Box<dyn PtySession>, PtyError> {
            let size = nix::pty::Winsize {
                ws_row: request.rows,
                ws_col: request.columns,
                ws_xpixel: 0,
                ws_ypixel: 0,
            };
            let OpenptyResult { master, slave } = nix::pty::openpty(Some(&size), None)?;
            let argv: Vec<std::ffi::CString> = request
                .shell
                .argv()
                .iter()
                .map(|part| std::ffi::CString::new(*part).expect("constant argv"))
                .collect();
            match unsafe { nix::unistd::fork() } {
                Ok(ForkResult::Parent { .. }) => {
                    drop(slave);
                    Ok(Box::new(FdPtySession::new(master)))
                }
                Ok(ForkResult::Child) => {
                    let _ = nix::unistd::setsid();
                    for target in [0, 1, 2] {
                        let _ = unsafe { nix::libc::dup2(slave.as_raw_fd(), target) };
                    }
                    let _ = nix::unistd::chdir(&self.working_directory);
                    let _ = nix::unistd::execvp(&argv[0], &argv);
                    unsafe { nix::libc::_exit(127) }
                }
                Err(errno) => Err(PtyError::Spawn(errno.to_string())),
            }
        }

        fn close(&self, _terminal_id: Uuid) -> Result<(), PtyError> {
            Ok(())
        }
    }
}

/// Echo input and replay scripted output for tests; never use this runner in production wiring.
#[derive(Debug, Default)]
pub struct ScriptedPtyRunner {
    outputs: std::sync::Mutex<std::collections::VecDeque<Vec<u8>>>,
    /// Record spawn requests so tests can verify the selected container and shell.
    requests: std::sync::Mutex<Vec<PtySpawnRequest>>,
    closed: std::sync::Mutex<Vec<Uuid>>,
    close_failure: std::sync::atomic::AtomicBool,
}

impl ScriptedPtyRunner {
    pub fn set_close_failure(&self, fail: bool) {
        self.close_failure
            .store(fail, std::sync::atomic::Ordering::SeqCst);
    }
    pub fn queue_output(&self, bytes: Vec<u8>) {
        self.outputs.lock().expect("output queue").push_back(bytes);
    }

    pub fn requests(&self) -> Vec<PtySpawnRequest> {
        self.requests.lock().expect("requests").clone()
    }

    pub fn closed(&self) -> Vec<Uuid> {
        self.closed.lock().expect("closed").clone()
    }
}

impl PtyRunner for ScriptedPtyRunner {
    fn spawn(&self, request: &PtySpawnRequest) -> Result<Box<dyn PtySession>, PtyError> {
        self.requests
            .lock()
            .expect("requests")
            .push(request.clone());
        Ok(Box::new(ScriptedPty {
            input: Vec::new(),
            outputs: self.outputs.lock().expect("outputs").clone(),
            size: (request.columns, request.rows),
        }))
    }

    fn close(&self, terminal_id: Uuid) -> Result<(), PtyError> {
        if self.close_failure.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(PtyError::Spawn("scripted close failure".into()));
        }
        self.closed.lock().expect("closed").push(terminal_id);
        Ok(())
    }
}

struct ScriptedPty {
    input: Vec<u8>,
    outputs: std::collections::VecDeque<Vec<u8>>,
    size: (u16, u16),
}

impl PtySession for ScriptedPty {
    fn write(&mut self, data: &[u8]) -> Result<(), PtyError> {
        // Echo semantics: typed bytes come back as terminal input echoes.
        self.input.extend_from_slice(data);
        Ok(())
    }

    fn read(&mut self) -> Result<Vec<u8>, PtyError> {
        if !self.input.is_empty() {
            let echoed = {
                let mut out = b"$ ".to_vec();
                out.extend_from_slice(&self.input);
                self.input.clear();
                out
            };
            if let Some(bytes) = self.outputs.pop_front() {
                let mut merged = bytes;
                merged.extend_from_slice(&echoed);
                return Ok(merged);
            }
            return Ok(echoed);
        }
        if let Some(bytes) = self.outputs.pop_front() {
            return Ok(bytes);
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
        Ok(Vec::new())
    }

    fn resize(&mut self, columns: u16, rows: u16) -> Result<(), PtyError> {
        self.size = (columns, rows);
        Ok(())
    }

    fn close(&mut self) {}

    fn child_pid(&self) -> Option<Pid> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> PtySpawnRequest {
        PtySpawnRequest {
            project_id: Uuid::new_v4(),
            terminal_id: Uuid::new_v4(),
            container_id: format!("spark-project-{}", Uuid::new_v4()),
            shell: TerminalShell::Login,
            columns: 120,
            rows: 40,
        }
    }

    #[test]
    fn scripted_pty_echoes_typed_lines() {
        let runner = ScriptedPtyRunner::default();
        let mut session = runner.spawn(&request()).unwrap();
        session.write(b"echo hi\n").unwrap();
        let out = session.read().unwrap();
        assert!(String::from_utf8_lossy(&out).contains("echo hi"));
        let _ = session.read();
    }

    #[test]
    fn scripted_pty_drains_queued_output_before_echo() {
        let runner = ScriptedPtyRunner::default();
        runner.queue_output(b"PROMPT> ".to_vec());
        let mut session = runner.spawn(&request()).unwrap();
        session.write(b"ls\n").unwrap();
        let out = session.read().unwrap();
        let text = String::from_utf8_lossy(&out);
        assert!(text.starts_with("PROMPT> "), "{text}");
        assert!(text.contains("ls"), "{text}");
    }

    #[test]
    fn a_spawn_request_carries_the_container_it_must_run_in() {
        let runner = ScriptedPtyRunner::default();
        let request = request();
        let _ = runner.spawn(&request).unwrap();
        let observed = runner.requests();
        assert_eq!(observed.len(), 1);
        assert_eq!(observed[0].container_id, request.container_id);
        assert_eq!(observed[0].shell, TerminalShell::Login);
    }

    #[test]
    fn a_descriptor_session_reads_writes_and_resizes() {
        let size = nix::pty::Winsize {
            ws_row: 24,
            ws_col: 80,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let nix::pty::OpenptyResult { master, slave } =
            nix::pty::openpty(Some(&size), None).unwrap();
        let mut session = FdPtySession::new(master);

        // Line-discipline echo proves the descriptor carries bytes in both directions.
        session.write(b"hello\n").unwrap();
        let mut seen = Vec::new();
        for _ in 0..20 {
            seen.extend(session.read().unwrap());
            if !seen.is_empty() {
                break;
            }
        }
        assert!(String::from_utf8_lossy(&seen).contains("hello"), "{seen:?}");

        session.resize(132, 50).unwrap();
        let mut observed = nix::libc::winsize {
            ws_row: 0,
            ws_col: 0,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let result = unsafe {
            nix::libc::ioctl(
                slave.as_raw_fd(),
                nix::libc::TIOCGWINSZ,
                &mut observed as *mut nix::libc::winsize,
            )
        };
        assert_eq!(result, 0);
        assert_eq!((observed.ws_col, observed.ws_row), (132, 50));

        session.close();
        assert!(matches!(session.read(), Err(PtyError::Closed)));
        assert!(matches!(session.write(b"x"), Err(PtyError::Closed)));
    }
}
