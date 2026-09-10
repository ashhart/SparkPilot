//! Implement packaged Type=notify readiness/watchdog/status messages; without NOTIFY_SOCKET calls return successful false no-ops.

use std::io;
use std::os::unix::net::UnixDatagram;
use std::time::Duration;

/// Environment variable naming the notification socket.
const NOTIFY_SOCKET: &str = "NOTIFY_SOCKET";
/// Watchdog interval published by systemd, in microseconds.
const WATCHDOG_USEC: &str = "WATCHDOG_USEC";
/// PID systemd expects watchdog pings from.
const WATCHDOG_PID: &str = "WATCHDOG_PID";

/// Send one newline-separated status datagram; return false without a notify socket and errors only for advertised-socket send failures.
pub fn notify(state: &str) -> io::Result<bool> {
    let Some(address) = std::env::var_os(NOTIFY_SOCKET) else {
        return Ok(false);
    };
    let address = address.to_string_lossy().into_owned();
    if address.is_empty() {
        return Ok(false);
    }
    let socket = connect(&address)?;
    socket.send(state.as_bytes())?;
    Ok(true)
}

/// Send READY only after binding and becoming able to serve requests.
pub fn ready() -> io::Result<bool> {
    notify("READY=1")
}

/// Feed the watchdog.
pub fn watchdog_ping() -> io::Result<bool> {
    notify("WATCHDOG=1")
}

/// Report that shutdown has begun.
pub fn stopping() -> io::Result<bool> {
    notify("STOPPING=1")
}

/// Publish a human-readable systemctl status line without prompts, credentials or other sensitive text.
pub fn status(text: &str) -> io::Result<bool> {
    if text.contains('\n') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "status text must be a single line",
        ));
    }
    notify(&format!("STATUS={text}"))
}

/// Ping at half the configured watchdog interval, or return None when this process has no armed watchdog.
pub fn watchdog_interval() -> Option<Duration> {
    let pid = std::env::var(WATCHDOG_PID).ok();
    if let Some(pid) = pid
        && pid.trim().parse::<u32>().ok() != Some(std::process::id())
    {
        return None;
    }
    let usec: u64 = std::env::var(WATCHDOG_USEC).ok()?.trim().parse().ok()?;
    if usec == 0 {
        return None;
    }
    Some(Duration::from_micros(usec / 2))
}

#[cfg(target_os = "linux")]
fn connect(address: &str) -> io::Result<UnixDatagram> {
    use std::os::linux::net::SocketAddrExt;
    use std::os::unix::net::SocketAddr;

    let socket = UnixDatagram::unbound()?;
    // systemd uses an abstract socket when the name starts with `@`.
    if let Some(name) = address.strip_prefix('@') {
        let addr = SocketAddr::from_abstract_name(name.as_bytes())?;
        socket.connect_addr(&addr)?;
    } else {
        socket.connect(address)?;
    }
    Ok(socket)
}

#[cfg(not(target_os = "linux"))]
fn connect(address: &str) -> io::Result<UnixDatagram> {
    if address.starts_with('@') {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "abstract notify sockets require Linux",
        ));
    }
    let socket = UnixDatagram::unbound()?;
    socket.connect(address)?;
    Ok(socket)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Serialize tests that modify process-global environment variables.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    struct ClearedEnv {
        // Keep ENV_LOCK held through Drop's environment cleanup; fields release afterward, preventing another test's variables being cleared.
        _guard: std::sync::MutexGuard<'static, ()>,
    }

    impl ClearedEnv {
        fn new() -> Self {
            let guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            unsafe {
                std::env::remove_var(NOTIFY_SOCKET);
                std::env::remove_var(WATCHDOG_USEC);
                std::env::remove_var(WATCHDOG_PID);
            }
            Self { _guard: guard }
        }
    }

    impl Drop for ClearedEnv {
        fn drop(&mut self) {
            unsafe {
                std::env::remove_var(NOTIFY_SOCKET);
                std::env::remove_var(WATCHDOG_USEC);
                std::env::remove_var(WATCHDOG_PID);
            }
        }
    }

    #[test]
    fn without_a_socket_every_message_is_a_no_op() {
        let _env = ClearedEnv::new();
        assert!(!ready().unwrap(), "no socket means nothing was sent");
        assert!(!watchdog_ping().unwrap());
        assert!(!stopping().unwrap());
        assert!(watchdog_interval().is_none());
    }

    #[test]
    fn ready_reaches_a_path_socket() {
        let _env = ClearedEnv::new();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("notify.sock");
        let listener = UnixDatagram::bind(&path).unwrap();
        unsafe { std::env::set_var(NOTIFY_SOCKET, &path) };

        assert!(ready().unwrap());

        let mut buffer = [0u8; 64];
        let read = listener.recv(&mut buffer).unwrap();
        assert_eq!(&buffer[..read], b"READY=1");
    }

    #[test]
    fn watchdog_interval_is_half_the_published_value() {
        let _env = ClearedEnv::new();
        unsafe {
            std::env::set_var(WATCHDOG_USEC, "30000000");
            std::env::set_var(WATCHDOG_PID, std::process::id().to_string());
        }
        assert_eq!(watchdog_interval(), Some(Duration::from_secs(15)));
    }

    #[test]
    fn watchdog_is_ignored_when_it_targets_another_process() {
        let _env = ClearedEnv::new();
        unsafe {
            std::env::set_var(WATCHDOG_USEC, "30000000");
            std::env::set_var(WATCHDOG_PID, (std::process::id() + 1).to_string());
        }
        assert!(watchdog_interval().is_none());
    }

    #[test]
    fn status_rejects_multi_line_text() {
        let _env = ClearedEnv::new();
        assert!(status("line one\nline two").is_err());
    }
}
