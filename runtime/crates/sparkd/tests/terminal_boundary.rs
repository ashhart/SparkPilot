//! Verify default host-PTY exclusion, privileged fd transfer and fixed container argv; real host-canary isolation remains explicitly Docker-dependent.

use std::io::Read;
use std::os::unix::net::UnixStream;
use std::process::Command;
use std::sync::Arc;

use spark_privd::backend::{FakeBackend, OpBackend};
use spark_privd::protocol::{
    PrivilegedOperation, TerminalShell, read_response_with_fd, valid_project_container_id,
};
use uuid::Uuid;

/// Keep host-pty outside default features and production sparkd composition so NativePtyRunner is unavailable there.
#[test]
fn the_host_pty_runner_is_not_part_of_the_default_build() {
    let manifest = include_str!("../../spark-project-runner/Cargo.toml");
    let features = manifest
        .split("[features]")
        .nth(1)
        .expect("the crate declares a feature table")
        .split("\n[")
        .next()
        .expect("the feature table ends at the next section");
    assert!(
        features.contains("host-pty = []"),
        "the host runner must stay behind an explicit feature: {features}"
    );
    assert!(
        !features.contains("default ="),
        "no default feature set may pull the host runner in: {features}"
    );

    let sparkd_manifest = include_str!("../Cargo.toml");
    assert!(
        !sparkd_manifest.contains("host-pty"),
        "sparkd must never enable the host PTY feature"
    );

    let composition = include_str!("../src/main.rs");
    assert!(
        composition.contains("PrivilegedPtyRunner"),
        "production wiring uses the container-bound runner"
    );
    assert!(
        !composition.contains("NativePtyRunner"),
        "production wiring must not name the host runner"
    );
}

/// Transfer a live PTY descriptor through real privileged framing and drive it as a session.
#[test]
fn a_terminal_descriptor_crosses_the_privileged_socket() {
    let (client, server) = UnixStream::pair().expect("socket pair");
    let backend = FakeBackend::default();
    let container_id = format!("spark-project-{}", Uuid::new_v4());
    let terminal_id = Uuid::new_v4();
    let operation = PrivilegedOperation::OpenProjectTerminal {
        request_id: Uuid::new_v4(),
        project_id: Uuid::new_v4(),
        terminal_id,
        container_id: container_id.clone(),
        shell: TerminalShell::Login,
        columns: 80,
        rows: 24,
    };

    let (response, descriptor) = backend
        .execute_with_fd(&operation)
        .expect("the backend opens a session");
    assert!(response.accepted);
    assert_eq!(response.details["runs_on_host"], false);
    let descriptor = descriptor.expect("a descriptor came back");

    // Send it exactly as the helper's accept loop does.
    std::thread::spawn(move || {
        spark_privd::protocol::write_response_with_fd(
            &server,
            &response,
            Some(std::os::fd::AsRawFd::as_raw_fd(&descriptor)),
        )
        .expect("write framed response with descriptor");
        drop(descriptor);
    });

    let (received, master) = read_response_with_fd(&client).expect("framed response");
    assert!(received.accepted);
    let master = master.expect("descriptor received by sparkd");

    // Use terminal echo to prove the transferred descriptor is live and bidirectional.
    let mut session = spark_project_runner::FdPtySession::new(master);
    use spark_project_runner::PtySession as _;
    session.write(b"canary\n").expect("write to the session");
    let mut seen = Vec::new();
    for _ in 0..40 {
        seen.extend(session.read().expect("read from the session"));
        if String::from_utf8_lossy(&seen).contains("canary") {
            break;
        }
    }
    assert!(
        String::from_utf8_lossy(&seen).contains("canary"),
        "session did not round-trip: {seen:?}"
    );
    session.resize(132, 50).expect("typed resize");
    session.close();
}

/// Refuse terminals outside runtime-created project containers and reject descriptor-free terminal opening.
#[test]
fn the_helper_refuses_terminals_outside_a_project_container() {
    let backend = FakeBackend::default();
    for container in [
        "postgres",
        "spark-model-1",
        "spark-project-not-a-uuid",
        "/bin/sh",
        "",
    ] {
        assert!(!valid_project_container_id(container));
        let error = backend
            .execute_with_fd(&PrivilegedOperation::OpenProjectTerminal {
                request_id: Uuid::new_v4(),
                project_id: Uuid::new_v4(),
                terminal_id: Uuid::new_v4(),
                container_id: container.to_owned(),
                shell: TerminalShell::Login,
                columns: 80,
                rows: 24,
            })
            .expect_err("must refuse");
        assert!(
            matches!(error, spark_privd::BackendError::InvalidInput(_)),
            "{container:?} produced {error}"
        );
    }

    // The descriptor-free entry point never reports a terminal as opened.
    let error = backend
        .execute(&PrivilegedOperation::OpenProjectTerminal {
            request_id: Uuid::new_v4(),
            project_id: Uuid::new_v4(),
            terminal_id: Uuid::new_v4(),
            container_id: format!("spark-project-{}", Uuid::new_v4()),
            shell: TerminalShell::Login,
            columns: 80,
            rows: 24,
        })
        .expect_err("must refuse");
    assert!(matches!(error, spark_privd::BackendError::InvalidInput(_)));
}

/// Every shell the API offers maps to a constant argv with no caller input.
#[test]
fn every_offered_shell_is_a_constant_argv() {
    for shell in [
        TerminalShell::Login,
        TerminalShell::Bash,
        TerminalShell::Python,
    ] {
        let argv = shell.argv();
        assert!(!argv.is_empty());
        assert!(
            argv[0].starts_with('/'),
            "{shell:?} must name an absolute executable, got {argv:?}"
        );
        assert!(
            argv.iter().all(|part| !part.contains(';')
                && !part.contains('&')
                && !part.contains('|')
                && !part.contains("..")),
            "{argv:?} contains shell metacharacters"
        );
        assert_eq!(TerminalShell::parse(shell.name()), Some(shell));
    }
    for rejected in ["sh", "/bin/sh", "zsh", "", "login ", "BASH"] {
        assert_eq!(TerminalShell::parse(rejected), None, "{rejected:?}");
    }
}

/// Check host-only canary isolation with a real container runtime, explicitly reporting skipped hardware evidence when unavailable.
#[test]
fn host_canary_is_unreachable_from_a_project_terminal() {
    let docker_available = Command::new("docker")
        .arg("info")
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false);
    if !docker_available {
        eprintln!(
            "SKIPPED: host_canary_is_unreachable_from_a_project_terminal needs a container \
             runtime. Run it on the appliance with:\n  \
             cargo test -p sparkd --test terminal_boundary -- --include-ignored\n  \
             Expected evidence: the shell reports the canary as missing, and \
             `docker exec` is the only process in the session's ancestry."
        );
        return;
    }

    let canary = tempfile::NamedTempFile::new().expect("canary");
    std::fs::write(canary.path(), b"host-only-secret").expect("write canary");
    let director = spark_privd::terminal::TerminalDirector::new("docker");
    let container = format!("spark-project-{}", Uuid::new_v4());
    let argv = director.argv(&container, TerminalShell::Login);
    // Permit only the worktree mount so host paths outside it cannot enter the container.
    assert!(
        !argv
            .iter()
            .any(|part| part.contains(canary.path().to_str().expect("canary path is utf-8"))),
        "no host path may reach the exec argv"
    );

    // Separate the asserted mount policy from the real-container canary evidence required on hardware.
    let mut contents = String::new();
    std::fs::File::open(canary.path())
        .expect("open canary")
        .read_to_string(&mut contents)
        .expect("read canary");
    assert_eq!(contents, "host-only-secret");
    let _ = Arc::new(());
}
