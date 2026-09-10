//! On root Linux, verify both service-group socket access and peer-UID rejection using distinct real accounts.

#![cfg(target_os = "linux")]

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use spark_privd::FakeBackend;
use spark_privd::protocol::{PrivilegedOperation, RequestIdTracker, write_request};
use spark_privd::server::{bind_socket_as_group, handle_connection};

/// Bound the accept loop so failed probes cannot leave tests or CI hanging.
const SERVER_DEADLINE: Duration = Duration::from_secs(20);

/// Accounts every Debian-derived image has, so the test needs no `useradd`.
const ALLOWED_ACCOUNT: &str = "daemon";
const OTHER_ACCOUNT: &str = "nobody";

struct Accounts {
    allowed_uid: u32,
    allowed_gid: u32,
    allowed_group: String,
    other_uid: u32,
    other_gid: u32,
}

fn accounts() -> Option<Accounts> {
    let allowed = nix::unistd::User::from_name(ALLOWED_ACCOUNT).ok()??;
    let other = nix::unistd::User::from_name(OTHER_ACCOUNT).ok()??;
    let allowed_group = nix::unistd::Group::from_gid(allowed.gid).ok()??;
    if allowed.uid == other.uid {
        return None;
    }
    Some(Accounts {
        allowed_uid: allowed.uid.as_raw(),
        allowed_gid: allowed.gid.as_raw(),
        allowed_group: allowed_group.name,
        other_uid: other.uid.as_raw(),
        other_gid: other.gid.as_raw(),
    })
}

fn skip(reason: &str) {
    eprintln!("skipping privileged socket test: {reason}");
}

/// Allocate before fork, then connect under the chosen UID/GID using only child-safe syscalls.
fn connect_as(socket: &Path, uid: u32, gid: u32, request: &[u8]) -> ChildOutcome {
    use nix::sys::wait::{WaitStatus, waitpid};
    use nix::unistd::{ForkResult, Gid, Uid, fork, setgid, setresgid, setresuid, setuid};

    let socket_path = socket.to_owned();
    let payload = request.to_vec();

    match unsafe { fork() } {
        Ok(ForkResult::Child) => {
            // Drop privileges before connecting so peer credentials identify the actual test account.
            let code = (|| -> i32 {
                let gid = Gid::from_raw(gid);
                let uid = Uid::from_raw(uid);
                if setgid(gid).is_err() || setresgid(gid, gid, gid).is_err() {
                    return EXIT_SETUP_FAILED;
                }
                if setuid(uid).is_err() || setresuid(uid, uid, uid).is_err() {
                    return EXIT_SETUP_FAILED;
                }
                let Ok(mut stream) = UnixStream::connect(&socket_path) else {
                    return EXIT_CONNECT_DENIED;
                };
                // Never block indefinitely on a helper that is not answering.
                let timeout = std::time::Duration::from_secs(5);
                if stream.set_read_timeout(Some(timeout)).is_err()
                    || stream.set_write_timeout(Some(timeout)).is_err()
                {
                    return EXIT_SETUP_FAILED;
                }
                if stream.write_all(&payload).is_err() || stream.flush().is_err() {
                    return EXIT_WRITE_FAILED;
                }
                let mut header = [0u8; 4];
                match stream.read_exact(&mut header) {
                    // A rejected peer receives EOF without a response body.
                    Err(_) => EXIT_REFUSED_BY_PEER_CHECK,
                    Ok(()) => EXIT_ANSWERED,
                }
            })();
            unsafe { nix::libc::_exit(code) };
        }
        Ok(ForkResult::Parent { child }) => match waitpid(child, None) {
            Ok(WaitStatus::Exited(_, code)) => ChildOutcome::from_code(code),
            other => panic!("child did not exit cleanly: {other:?}"),
        },
        Err(error) => panic!("fork failed: {error}"),
    }
}

const EXIT_ANSWERED: i32 = 0;
const EXIT_CONNECT_DENIED: i32 = 10;
const EXIT_REFUSED_BY_PEER_CHECK: i32 = 11;
const EXIT_WRITE_FAILED: i32 = 12;
const EXIT_SETUP_FAILED: i32 = 13;

#[derive(Debug, PartialEq, Eq)]
enum ChildOutcome {
    Answered,
    ConnectDenied,
    RefusedByPeerCheck,
    WriteFailed,
    SetupFailed,
    Unknown(i32),
}

impl ChildOutcome {
    fn from_code(code: i32) -> Self {
        match code {
            EXIT_ANSWERED => Self::Answered,
            EXIT_CONNECT_DENIED => Self::ConnectDenied,
            EXIT_REFUSED_BY_PEER_CHECK => Self::RefusedByPeerCheck,
            EXIT_WRITE_FAILED => Self::WriteFailed,
            EXIT_SETUP_FAILED => Self::SetupFailed,
            other => Self::Unknown(other),
        }
    }
}

fn probe_request() -> Vec<u8> {
    let mut bytes = Vec::new();
    write_request(
        &mut bytes,
        &PrivilegedOperation::ProbeContainerRuntime {
            request_id: uuid::Uuid::new_v4(),
        },
    )
    .expect("encode probe");
    bytes
}

#[test]
fn the_service_account_connects_and_an_unrelated_account_does_not() {
    if !nix::unistd::geteuid().is_root() {
        skip("needs root to change uid; run inside the Arm64 build container");
        return;
    }
    let Some(accounts) = accounts() else {
        skip("this image lacks the two unprivileged accounts the test needs");
        return;
    };

    let dir = tempfile::tempdir().expect("temp dir");
    // Match the packaged helper-owned directory and socket layout.
    let run_dir = dir.path().join("spark-runtime");
    let socket = run_dir.join("spark-privd.sock");

    let listener = bind_socket_as_group(&socket, Some(&accounts.allowed_group))
        .expect("bind with the service group");

    // The directory must be traversable by the group and nobody else.
    let dir_mode = std::fs::metadata(&run_dir).unwrap().permissions().mode() & 0o777;
    assert_eq!(dir_mode, 0o750, "run directory mode");
    let socket_mode = std::fs::metadata(&socket).unwrap().permissions().mode() & 0o777;
    assert_eq!(socket_mode, 0o660, "socket mode");
    assert_eq!(group_of(&socket), accounts.allowed_gid, "socket group");
    assert_eq!(owner_of(&socket), 0, "socket stays root-owned");

    // Use a nonblocking, deadline-bounded accept loop because unlinking a socket does not interrupt a blocked listener.
    listener
        .set_nonblocking(true)
        .expect("non-blocking listener");

    let stop = Arc::new(AtomicBool::new(false));
    let server_stop = stop.clone();
    let allowed_uid = accounts.allowed_uid;
    let server = std::thread::spawn(move || {
        let backend = FakeBackend::default();
        let mut tracker = RequestIdTracker::new();
        let deadline = Instant::now() + SERVER_DEADLINE;
        while !server_stop.load(Ordering::SeqCst) && Instant::now() < deadline {
            match listener.accept() {
                Ok((stream, _)) => {
                    stream
                        .set_nonblocking(false)
                        .expect("blocking accepted stream");
                    handle_connection(stream, allowed_uid, &backend, &mut tracker);
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(_) => break,
            }
        }
    });

    let request = probe_request();

    assert_eq!(
        connect_as(
            &socket,
            accounts.allowed_uid,
            accounts.allowed_gid,
            &request
        ),
        ChildOutcome::Answered,
        "the configured service account must be able to reach the helper"
    );

    assert!(
        matches!(
            connect_as(&socket, accounts.other_uid, accounts.other_gid, &request),
            ChildOutcome::ConnectDenied | ChildOutcome::RefusedByPeerCheck
        ),
        "an unrelated account must be refused, by the filesystem or by SO_PEERCRED"
    );

    stop.store(true, Ordering::SeqCst);
    server.join().expect("the bounded server thread terminates");
    drop(dir);
}

use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::PermissionsExt;

fn group_of(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().gid()
}

fn owner_of(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().uid()
}
