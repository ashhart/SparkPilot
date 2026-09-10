//! `spark-privd` binary: typed privilege helper over a Unix socket.

use std::path::PathBuf;
use std::sync::Arc;

use clap::Parser;
use nix::unistd::geteuid;
use spark_privd::backend::DockerBackend;
use spark_privd::server::{
    AcceptLoopHeartbeat, bind_socket_as_group, default_socket_path, serve_with_heartbeat,
};

#[derive(Debug, Parser)]
#[command(
    name = "spark-privd",
    about = "Spark Runtime privileged helper (typed operations only)"
)]
struct Cli {
    /// Privileged socket path.
    #[arg(long)]
    socket: Option<PathBuf>,

    /// UID admitted to submit operations; development defaults to the helper's own euid.
    #[arg(long)]
    allowed_uid: Option<u32>,

    /// Resolve the packaged service account at startup because installation assigns its UID dynamically.
    #[arg(long, conflicts_with = "allowed_uid")]
    allowed_user: Option<String>,

    /// Grant the service group socket access while retaining root ownership.
    #[arg(long)]
    socket_group: Option<String>,

    /// Docker CLI used by the model backend.
    #[arg(long, default_value = "docker")]
    docker_bin: String,

    /// Validate and report planned argv without executing docker.
    #[arg(long)]
    plan_only: bool,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();

    let filter =
        tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into());
    tracing_subscriber::fmt().with_env_filter(filter).init();

    let socket = cli.socket.unwrap_or_else(default_socket_path);
    let allowed_uid = match (cli.allowed_uid, cli.allowed_user.as_deref()) {
        (Some(uid), _) => uid,
        (None, Some(name)) => resolve_uid(name)?,
        (None, None) => geteuid().as_raw(),
    };

    if !cli.plan_only
        && let Err(error) = spark_privd::cpu_power::restore_after_boot()
    {
        tracing::warn!(%error, "saved CPU ceilings could not be restored");
    }
    let mut backend = DockerBackend::new(cli.docker_bin, cli.plan_only);
    // Match staged-file ownership to the UID admitted by peer credentials.
    backend = backend.with_service_uid(allowed_uid);
    // Share the engine cache through the configured service group.
    backend = backend.with_service_gid(primary_gid(allowed_uid));
    backend.cleanup_stale_credentials()?;
    backend.reconcile_inference_firewall()?;
    let listener = bind_socket_as_group(&socket, cli.socket_group.as_deref())?;
    tracing::info!(
        socket = %socket.display(),
        allowed_uid,
        socket_group = cli.socket_group.as_deref().unwrap_or("<unchanged>"),
        "serving privileged operations"
    );

    // Notify readiness only after binding the socket so systemd cannot start dependents too early.
    if let Err(error) = spark_core::notify::ready() {
        tracing::warn!(%error, "failed to report readiness to systemd");
    }

    // Watch accept-loop progress so a blocked handler cannot appear healthy merely because its watchdog thread runs.
    let heartbeat = Arc::new(AcceptLoopHeartbeat::new());
    spawn_watchdog(heartbeat.clone());

    serve_with_heartbeat(listener, allowed_uid, &backend, &heartbeat)?;
    let _ = spark_core::notify::stopping();
    Ok(())
}

/// Resolve the service UID and fail if the account is missing.
fn resolve_uid(name: &str) -> Result<u32, Box<dyn std::error::Error>> {
    let user = nix::unistd::User::from_name(name)
        .map_err(|error| format!("failed to look up user {name:?}: {error}"))?
        .ok_or_else(|| format!("user {name:?} does not exist"))?;
    Ok(user.uid.as_raw())
}

/// Use the admitted account's primary group, falling back to this process's group if lookup fails.
fn primary_gid(uid: u32) -> u32 {
    nix::unistd::User::from_uid(nix::unistd::Uid::from_raw(uid))
        .ok()
        .flatten()
        .map(|user| user.gid.as_raw())
        .unwrap_or_else(|| nix::unistd::getegid().as_raw())
}

/// Feed systemd only while the accept loop waits or handles within budget; see docs/development/privileged-boundaries.md.
fn spawn_watchdog(heartbeat: Arc<AcceptLoopHeartbeat>) {
    let Some(interval) = spark_core::notify::watchdog_interval() else {
        return;
    };
    let budget = interval.saturating_mul(2);
    std::thread::Builder::new()
        .name("privd-watchdog".to_owned())
        .spawn(move || {
            loop {
                std::thread::sleep(interval);
                if !heartbeat.is_healthy(budget) {
                    tracing::error!(
                        budget_ms = budget.as_millis() as u64,
                        "the accept loop is not making progress; no longer feeding the \
                         watchdog so systemd restarts this helper"
                    );
                    return;
                }
                if let Err(error) = spark_core::notify::watchdog_ping() {
                    tracing::warn!(%error, "watchdog ping failed");
                    return;
                }
            }
        })
        .ok();
}
