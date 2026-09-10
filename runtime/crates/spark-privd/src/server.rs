//! Authenticate each Unix-socket peer against the configured daemon UID before accepting operations.

use std::collections::HashMap;
use std::fs;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use thiserror::Error;
use tracing::{debug, warn};
use uuid::Uuid;

use crate::backend::OpBackend;
use crate::protocol::{
    PrivilegedResponse, ProtocolError, RequestIdTracker, read_request, write_response,
    write_response_with_fd,
};

/// Socket directory mode.
pub const SOCKET_DIR_UMASK_MODE: u32 = 0o750;
/// Socket mode is 0660 with root:service-group ownership.
pub const SOCKET_FILE_UMASK_MODE: u32 = 0o660;
/// Bound workers while retaining capacity for emergency operations during slow mutations.
pub const MAX_CONCURRENT_CONNECTIONS: usize = 8;
/// Bound the waiting-peer queue to prevent local socket pressure from exhausting memory.
pub const MAX_PENDING_CONNECTIONS: usize = MAX_CONCURRENT_CONNECTIONS * 4;
/// The daemon opens one connection per request and writes at once, so a silent peer is holding a worker hostage.
pub const IDLE_READ_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Error)]
pub enum ServerError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("peer credential lookup failed: {0}")]
    PeerCredentials(String),
    #[error("unsupported platform for peer credentials")]
    PeerCredentialsUnsupported,
    #[error("group {0:?} does not exist")]
    GroupNotFound(String),
    #[error("failed to set the group of {path}: {reason}")]
    Chown { path: PathBuf, reason: String },
}

/// Read peer credentials with SO_PEERCRED on Linux or getpeereid on Apple platforms.
pub fn peer_euid(stream: &UnixStream) -> Result<u32, ServerError> {
    #[cfg(target_os = "linux")]
    {
        use nix::sys::socket::{getsockopt, sockopt::PeerCredentials};

        let cred = getsockopt(stream, PeerCredentials)
            .map_err(|errno| ServerError::PeerCredentials(errno.to_string()))?;
        Ok(cred.uid())
    }
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        use std::os::unix::io::AsRawFd;
        let mut euid: libc::uid_t = 0;
        let mut egid: libc::gid_t = 0;
        let rc = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut euid, &mut egid) };
        if rc != 0 {
            return Err(ServerError::Io(std::io::Error::last_os_error()));
        }
        Ok(euid)
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "ios")))]
    {
        let _ = stream;
        Err(ServerError::PeerCredentialsUnsupported)
    }
}

/// Authenticate one peer, then handle requests with duplicate-ID rejection until EOF.
pub fn handle_connection(
    stream: UnixStream,
    allowed_uid: u32,
    backend: &dyn OpBackend,
    tracker: &mut RequestIdTracker,
) {
    handle_connection_with_timeout(stream, allowed_uid, backend, tracker, IDLE_READ_TIMEOUT);
}

/// Handle one connection whose reads and writes give up after `idle`; tests shorten it.
pub fn handle_connection_with_timeout(
    mut stream: UnixStream,
    allowed_uid: u32,
    backend: &dyn OpBackend,
    tracker: &mut RequestIdTracker,
    idle: Duration,
) {
    let mut observe_request = |request_id| tracker.observe(request_id);
    handle_connection_inner(
        &mut stream,
        allowed_uid,
        backend,
        &mut observe_request,
        None,
        idle,
    );
}

fn handle_connection_inner(
    stream: &mut UnixStream,
    allowed_uid: u32,
    backend: &dyn OpBackend,
    observe_request: &mut dyn FnMut(Uuid) -> bool,
    heartbeat: Option<&HandlerHeartbeat<'_>>,
    idle: Duration,
) {
    if let Err(error) = stream
        .set_read_timeout(Some(idle))
        .and_then(|()| stream.set_write_timeout(Some(idle)))
    {
        warn!(%error, "failed to bound the connection; refusing it");
        return;
    }
    match peer_euid(stream) {
        Ok(uid) if uid == allowed_uid => {}
        Ok(other) => {
            warn!(
                uid = other,
                allowed = allowed_uid,
                "refusing socket peer with wrong uid"
            );
            return;
        }
        Err(error) => {
            warn!(%error, "failed to read peer credentials; refusing connection");
            return;
        }
    }

    loop {
        let operation = match read_request(&mut *stream) {
            Ok(op) => op,
            Err(ProtocolError::Io(error)) if error.kind() == std::io::ErrorKind::UnexpectedEof => {
                debug!("client closed connection");
                return;
            }
            Err(ProtocolError::Io(error)) => {
                // A timed-out or broken stream has no frame boundary left to resume from.
                debug!(%error, "closing an unreadable connection");
                return;
            }
            Err(error) => {
                debug!(%error, "refusing a malformed frame");
                let response = PrivilegedResponse::rejected(
                    Uuid::nil(),
                    "protocol_error",
                    refusal_message(&error),
                );
                let _ = write_response(&mut *stream, &response);
                // An oversized declaration left its payload unread, so the stream can only desynchronise; close it.
                if matches!(error, ProtocolError::RequestTooLarge) {
                    return;
                }
                continue;
            }
        };

        let request_id = operation.request_id();
        if request_id.is_nil() {
            let response = PrivilegedResponse::rejected(
                request_id,
                "invalid_request",
                "request id must not be nil",
            );
            let _ = write_response(&mut *stream, &response);
            continue;
        }
        if !observe_request(request_id) {
            let response = PrivilegedResponse::rejected(
                request_id,
                "duplicate_request",
                "request id already processed",
            );
            let _ = write_response(&mut *stream, &response);
            continue;
        }

        if let Some(budget) = handling_budget(operation.kind())
            && let Some(heartbeat) = heartbeat
        {
            heartbeat.allow_handling_for(budget);
        }
        // Route every operation through descriptor-aware dispatch; descriptor passing requires explicit backend support.
        let (response, descriptor) = match backend.execute_with_fd(&operation) {
            Ok(outcome) => outcome,
            Err(error) => {
                // Log rejection reasons locally as well as returning them to the daemon.
                tracing::warn!(
                    operation = operation.kind(),
                    %error,
                    "privileged operation failed"
                );
                (
                    PrivilegedResponse::rejected(request_id, "backend_error", &error.to_string()),
                    None,
                )
            }
        };
        if let Some(heartbeat) = heartbeat {
            heartbeat.clear_handling_override();
        }

        let written = match &descriptor {
            Some(fd) => write_response_with_fd(stream, &response, Some(fd.as_raw_fd())),
            None => write_response(&mut *stream, &response),
        };
        drop(descriptor);
        if let Err(error) = written {
            warn!(%error, "failed to write privileged response");
            return;
        }
    }
}

/// Return error categories because serde_json details may echo attacker-controlled payloads.
fn refusal_message(error: &ProtocolError) -> &'static str {
    match error {
        ProtocolError::RequestTooLarge => "request exceeds the frame limit",
        ProtocolError::InvalidFrame(_) => "invalid frame",
        ProtocolError::Json(_) => "payload is not a typed operation",
        ProtocolError::Io(_) => "the frame could not be read",
    }
}

/// Budget operations explicitly so watchdog recovery cannot interrupt legitimate long-running mutations.
pub fn handling_budget(kind: &str) -> Option<Duration> {
    match kind {
        // Pulls a multi-gigabyte engine image over the network.
        "ensure_engine_image" => Some(Duration::from_secs(65 * 60)),
        "start_model" => Some(Duration::from_secs(65 * 60)),
        "install_kokoro" | "update_kokoro" => Some(Duration::from_secs(35 * 60)),
        "enable_kokoro" => Some(Duration::from_secs(180)),
        "disable_kokoro" | "remove_kokoro" => Some(Duration::from_secs(120)),
        // Allow image download and health-gated service replacement.
        "install_open_webui" | "update_open_webui" => Some(Duration::from_secs(35 * 60)),
        "repair_open_webui" => Some(Duration::from_secs(210)),
        // `apt-get dist-upgrade` plus firmware refresh.
        "refresh_system_updates" | "install_system_updates" => Some(Duration::from_secs(30 * 60)),
        // Exceed nmcli's 90-second wait plus startup so the helper survives network changes.
        "connect_wifi" | "configure_travel_ap" => Some(Duration::from_secs(180)),
        // Include duplicate-address probing and activation before the rollback timer starts.
        "configure_lan_ipv4" => Some(Duration::from_secs(60)),
        // Include NetworkManager's 90-second wait and ownership-checked cleanup.
        "configure_cluster_link" => Some(Duration::from_secs(120)),
        // Include the 180-second collective timeout, ten-second kill window and container cleanup.
        "run_cluster_two_rank_test" => Some(Duration::from_secs(210)),
        // Include worker-identity wait and digest-bound engine startup verification.
        "start_cluster_launch" => Some(Duration::from_secs(120)),
        // Walks the whole container and image store.
        "prune_container_storage" => Some(Duration::from_secs(10 * 60)),
        // A vendor package install over the network plus the 15-second sign-in window.
        "prepare_tailscale" => Some(Duration::from_secs(15 * 60)),
        "configure_tailscale" => Some(Duration::from_secs(100)),
        _ => None,
    }
}

/// Bind without changing group ownership only when the process already uses the required service group.
pub fn bind_socket(path: &Path) -> Result<UnixListener, ServerError> {
    bind_socket_as_group(path, None)
}

/// Set root:service-group ownership for socket access; peer credentials still decide authorization.
pub fn bind_socket_as_group(path: &Path, group: Option<&str>) -> Result<UnixListener, ServerError> {
    let gid = match group {
        Some(name) => Some(resolve_group(name)?),
        None => None,
    };

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
        // Inspect the name itself: a link here would carry the mode and group change to its target.
        let metadata = fs::symlink_metadata(parent)?;
        if !metadata.is_dir() {
            return Err(not_the_expected_kind(parent, "a directory"));
        }
        if metadata.permissions().mode() & 0o777 != SOCKET_DIR_UMASK_MODE {
            fs::set_permissions(parent, fs::Permissions::from_mode(SOCKET_DIR_UMASK_MODE))?;
        }
        if let Some(gid) = gid {
            // Permit directory traversal only for root and the service group.
            chown(parent, gid)?;
        }
    }
    // remove_file unlinks a planted link rather than following it.
    if fs::symlink_metadata(path).is_ok() {
        fs::remove_file(path)?;
    }
    let listener = UnixListener::bind(path)?;
    if !fs::symlink_metadata(path)?.file_type().is_socket() {
        return Err(not_the_expected_kind(path, "the bound socket"));
    }
    fs::set_permissions(path, fs::Permissions::from_mode(SOCKET_FILE_UMASK_MODE))?;
    if let Some(gid) = gid {
        chown(path, gid)?;
    }
    Ok(listener)
}

fn not_the_expected_kind(path: &Path, expected: &str) -> ServerError {
    ServerError::Io(std::io::Error::other(format!(
        "{} is not {expected}",
        path.display()
    )))
}

fn resolve_group(name: &str) -> Result<nix::unistd::Gid, ServerError> {
    let group = nix::unistd::Group::from_name(name)
        .map_err(|error| ServerError::PeerCredentials(error.to_string()))?
        .ok_or_else(|| ServerError::GroupNotFound(name.to_owned()))?;
    Ok(group.gid)
}

/// `lchown(path, -1, gid)`: leave the owner as root and set the group of the name itself, never a link target.
fn chown(path: &Path, gid: nix::unistd::Gid) -> Result<(), ServerError> {
    nix::unistd::fchownat(
        nix::fcntl::AT_FDCWD,
        path,
        None,
        Some(gid),
        nix::fcntl::AtFlags::AT_SYMLINK_NOFOLLOW,
    )
    .map_err(|error| ServerError::Chown {
        path: path.to_path_buf(),
        reason: error.to_string(),
    })
}

/// Track waiting versus handling states so indefinite healthy idleness differs from a wedged handler.
#[derive(Debug, Default)]
struct HeartbeatState {
    next_handler_id: u64,
    handlers: HashMap<u64, HandlerTiming>,
}

#[derive(Debug)]
struct HandlerTiming {
    since_millis: u64,
    budget_override_millis: u64,
}

#[derive(Debug, Default)]
pub struct AcceptLoopHeartbeat {
    handlers: parking_lot::Mutex<HeartbeatState>,
    started: OnceLock<Instant>,
    finished: AtomicBool,
    test_handler_id: AtomicU64,
}

struct HandlerHeartbeat<'a> {
    heartbeat: &'a AcceptLoopHeartbeat,
    handler_id: u64,
}

impl HandlerHeartbeat<'_> {
    fn allow_handling_for(&self, duration: Duration) {
        self.heartbeat.allow_handler_for(self.handler_id, duration);
    }

    fn clear_handling_override(&self) {
        self.heartbeat.clear_handler_override(self.handler_id);
    }
}

impl Drop for HandlerHeartbeat<'_> {
    fn drop(&mut self) {
        self.heartbeat.finish_handler(self.handler_id);
    }
}

impl AcceptLoopHeartbeat {
    pub fn new() -> Self {
        let heartbeat = Self::default();
        let _ = heartbeat.started.set(Instant::now());
        heartbeat
    }

    fn now_millis(&self) -> u64 {
        let started = self.started.get_or_init(Instant::now);
        // Saturate elapsed-time conversion to avoid overflow.
        started.elapsed().as_millis().min(u64::MAX as u128) as u64
    }

    fn finish(&self) {
        self.finished.store(true, Ordering::SeqCst);
    }

    fn begin_handler(&self) -> HandlerHeartbeat<'_> {
        let mut state = self.handlers.lock();
        state.next_handler_id = state.next_handler_id.wrapping_add(1).max(1);
        let handler_id = state.next_handler_id;
        state.handlers.insert(
            handler_id,
            HandlerTiming {
                since_millis: self.now_millis().max(1),
                budget_override_millis: 0,
            },
        );
        HandlerHeartbeat {
            heartbeat: self,
            handler_id,
        }
    }

    fn finish_handler(&self, handler_id: u64) {
        self.handlers.lock().handlers.remove(&handler_id);
    }

    fn allow_handler_for(&self, handler_id: u64, duration: Duration) {
        if let Some(timing) = self.handlers.lock().handlers.get_mut(&handler_id) {
            timing.budget_override_millis = duration.as_millis().min(u64::MAX as u128) as u64;
        }
    }

    fn clear_handler_override(&self, handler_id: u64) {
        if let Some(timing) = self.handlers.lock().handlers.get_mut(&handler_id) {
            timing.budget_override_millis = 0;
        }
    }

    /// Expose accept-loop state transitions for deterministic watchdog tests.
    pub fn begin_handling_for_test(&self) {
        let handler = self.begin_handler();
        self.test_handler_id
            .store(handler.handler_id, Ordering::SeqCst);
        std::mem::forget(handler);
    }

    pub fn finish_handling_for_test(&self) {
        let handler_id = self.test_handler_id.swap(0, Ordering::SeqCst);
        self.finish_handler(handler_id);
    }

    pub fn allow_handling_for_test(&self, duration: Duration) {
        let handler_id = self.test_handler_id.load(Ordering::SeqCst);
        self.allow_handler_for(handler_id, duration);
    }

    pub fn finish_for_test(&self) {
        self.finish();
    }

    /// Treat handling beyond its budget as unhealthy; keep the budget below systemd's WatchdogSec.
    pub fn is_healthy(&self, handling_budget: Duration) -> bool {
        if self.finished.load(Ordering::SeqCst) {
            return false;
        }
        let now_millis = self.now_millis();
        self.handlers.lock().handlers.values().all(|timing| {
            let elapsed = now_millis.saturating_sub(timing.since_millis);
            let effective_budget =
                handling_budget.max(Duration::from_millis(timing.budget_override_millis));
            Duration::from_millis(elapsed) < effective_budget
        })
    }
}

/// Run the accept loop until the listener fails.
pub fn serve(
    listener: UnixListener,
    allowed_uid: u32,
    backend: &dyn OpBackend,
) -> Result<(), ServerError> {
    serve_with_heartbeat(listener, allowed_uid, backend, &AcceptLoopHeartbeat::new())
}

/// Run the accept loop, publishing what it is doing.
pub fn serve_with_heartbeat(
    listener: UnixListener,
    allowed_uid: u32,
    backend: &dyn OpBackend,
    heartbeat: &AcceptLoopHeartbeat,
) -> Result<(), ServerError> {
    // Share replay tracking across connections and revoke liveness whenever the accept loop exits or unwinds.
    struct FinishGuard<'a>(&'a AcceptLoopHeartbeat);
    impl Drop for FinishGuard<'_> {
        fn drop(&mut self) {
            self.0.finish();
        }
    }
    let _finish = FinishGuard(heartbeat);

    // Bound workers and queued peers; hold the global replay lock only for ID observation, never backend execution.
    let tracker = parking_lot::Mutex::new(RequestIdTracker::new());
    let (sender, receiver) = mpsc::sync_channel(MAX_PENDING_CONNECTIONS);
    let receiver = Arc::new(parking_lot::Mutex::new(receiver));

    std::thread::scope(|scope| {
        for worker_index in 0..MAX_CONCURRENT_CONNECTIONS {
            let receiver = receiver.clone();
            let tracker = &tracker;
            std::thread::Builder::new()
                .name(format!("privd-connection-{worker_index}"))
                .spawn_scoped(scope, move || {
                    loop {
                        let Ok(mut stream) = receiver.lock().recv() else {
                            return;
                        };
                        let handler_heartbeat = heartbeat.begin_handler();
                        let mut observe_request = |request_id| tracker.lock().observe(request_id);
                        handle_connection_inner(
                            &mut stream,
                            allowed_uid,
                            backend,
                            &mut observe_request,
                            Some(&handler_heartbeat),
                            IDLE_READ_TIMEOUT,
                        );
                    }
                })?;
        }

        let result = loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    if sender.send(stream).is_err() {
                        break Err(ServerError::Io(std::io::Error::new(
                            std::io::ErrorKind::BrokenPipe,
                            "all privileged connection workers exited",
                        )));
                    }
                }
                Err(error) => {
                    warn!(%error, "accept failed");
                    break Err(ServerError::Io(error));
                }
            }
        };
        drop(sender);
        result
    })
}

/// Return the packaged privileged socket path.
pub fn default_socket_path() -> PathBuf {
    PathBuf::from(crate::SOCKET_PATH)
}

#[cfg(test)]
#[path = "server/tests.rs"]
mod tests;
