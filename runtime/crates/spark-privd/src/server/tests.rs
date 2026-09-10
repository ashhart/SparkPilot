use super::*;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;

#[test]
fn peer_euid_returns_current_user() {
    // A self-connected socket reports the caller's own euid.
    let (a, b) = UnixStream::pair().unwrap();
    std::mem::drop(a);
    let uid = peer_euid(&b).expect("peer euid readable on this platform");
    let expected = unsafe { libc::geteuid() };
    assert_eq!(uid, expected);
    let _ = b.as_raw_fd();
}

#[test]
fn bounded_image_pull_can_extend_the_handler_watchdog_budget() {
    let heartbeat = AcceptLoopHeartbeat::new();
    let handler = heartbeat.begin_handler();
    handler.allow_handling_for(Duration::from_secs(5));
    std::thread::sleep(Duration::from_millis(20));
    assert!(heartbeat.is_healthy(Duration::from_millis(1)));
    handler.clear_handling_override();
    assert!(!heartbeat.is_healthy(Duration::from_millis(1)));
}

#[test]
fn one_slow_operation_does_not_hide_an_unrelated_wedged_handler() {
    let heartbeat = AcceptLoopHeartbeat::new();
    let slow_handler = heartbeat.begin_handler();
    slow_handler.allow_handling_for(Duration::from_secs(5));
    let _wedged_handler = heartbeat.begin_handler();

    std::thread::sleep(Duration::from_millis(20));

    assert!(!heartbeat.is_healthy(Duration::from_millis(1)));
}

/// A backend the connection tests never reach.
struct RefusingBackend;

impl OpBackend for RefusingBackend {
    fn execute(
        &self,
        operation: &crate::protocol::PrivilegedOperation,
    ) -> Result<PrivilegedResponse, crate::backend::BackendError> {
        Ok(PrivilegedResponse::rejected(
            operation.request_id(),
            "not_executed",
            "the connection tests perform no work",
        ))
    }
}

/// A peer that connects and then says nothing must not hold a worker for longer than the idle bound.
#[test]
fn a_silent_peer_is_disconnected_after_the_idle_timeout() {
    let (client, server) = UnixStream::pair().unwrap();
    let uid = unsafe { libc::geteuid() };
    let started = Instant::now();
    let handler = std::thread::spawn(move || {
        let mut tracker = RequestIdTracker::new();
        handle_connection_with_timeout(
            server,
            uid,
            &RefusingBackend,
            &mut tracker,
            Duration::from_millis(200),
        );
    });
    handler.join().unwrap();
    let elapsed = started.elapsed();
    assert!(
        elapsed >= Duration::from_millis(150) && elapsed < Duration::from_secs(5),
        "handler returned after {elapsed:?}"
    );
    drop(client);
}

/// A link planted at the socket name is unlinked, never followed into a chmod or chown of its target.
#[test]
fn binding_replaces_a_planted_link_without_touching_its_target() {
    let dir = tempfile::tempdir().unwrap();
    let victim = dir.path().join("victim");
    fs::write(&victim, b"keep").unwrap();
    fs::set_permissions(&victim, fs::Permissions::from_mode(0o600)).unwrap();
    let socket = dir.path().join("run").join("privd.sock");
    fs::create_dir_all(socket.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&victim, &socket).unwrap();

    let _listener = bind_socket(&socket).unwrap();

    let bound = fs::symlink_metadata(&socket).unwrap();
    assert!(bound.file_type().is_socket());
    assert_eq!(bound.permissions().mode() & 0o777, SOCKET_FILE_UMASK_MODE);
    let untouched = fs::metadata(&victim).unwrap();
    assert_eq!(untouched.permissions().mode() & 0o777, 0o600);
    assert_eq!(fs::read(&victim).unwrap(), b"keep");
    assert_eq!(
        fs::symlink_metadata(socket.parent().unwrap())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        SOCKET_DIR_UMASK_MODE
    );
}
