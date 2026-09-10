#![cfg(feature = "host-pty")]

//! PTY reads must not block while the session mutex is held, or input and resize cannot proceed.

use std::sync::mpsc;
use std::time::{Duration, Instant};

use spark_project_runner::pty::{
    NativePtyRunner, PtyRunner, PtySession, PtySpawnRequest, TerminalShell,
};
use uuid::Uuid;

/// Run each scenario under a watchdog thread so a wedged read fails rather than hanging the harness.
fn with_watchdog(
    budget: Duration,
    scenario: impl FnOnce(&mut Box<dyn PtySession>) -> Result<(), String> + Send + 'static,
) {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let dir = tempfile::tempdir().unwrap();
        let runner = NativePtyRunner::new(dir.path());
        let mut session = runner
            .spawn(&PtySpawnRequest {
                project_id: Uuid::new_v4(),
                terminal_id: Uuid::new_v4(),
                container_id: "host-test".into(),
                shell: TerminalShell::Login,
                columns: 80,
                rows: 24,
            })
            .expect("spawn a quiet login shell");
        let _ = tx.send(scenario(&mut session));
    });
    match rx.recv_timeout(budget) {
        Ok(Ok(())) => {}
        Ok(Err(message)) => panic!("scenario failed: {message}"),
        Err(_) => panic!("scenario did not finish within the budget; read is wedged"),
    }
}

#[test]
fn quiet_pty_read_returns_instead_of_blocking() {
    with_watchdog(Duration::from_secs(4), |session| {
        let _ = session.read().map_err(|e| e.to_string())?;
        Ok(())
    });
}

#[test]
fn pty_read_still_delivers_output_after_the_quiet_path() {
    with_watchdog(Duration::from_secs(6), |session| {
        session.write(b"echo ping\n").map_err(|e| e.to_string())?;
        let deadline = Instant::now() + Duration::from_secs(4);
        loop {
            if Instant::now() > deadline {
                return Err("echoed input never arrived".into());
            }
            let bytes = session.read().map_err(|e| e.to_string())?;
            if String::from_utf8_lossy(&bytes).contains("ping") {
                session.close();
                return Ok(());
            }
        }
    });
}
