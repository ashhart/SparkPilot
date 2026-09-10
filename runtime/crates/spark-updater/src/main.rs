//! Verify and stage through typed privileged handoff; the root worker re-verifies, installs, health-gates and commits or rolls back.

use std::path::Path;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use spark_installer::trust::ReleaseTrustRoot;
use spark_updater::apply;
use spark_updater::health;

const DEFAULT_DATA_DIR: &str = "/var/lib/spark-runtime";
const DEFAULT_PRIVILEGED_SOCKET: &str = "/run/spark-runtime/spark-privd.sock";
const DEFAULT_TRUST_ROOT: &str = spark_installer::trust::INSTALLED_TRUST_ROOT;

#[derive(Debug, Parser)]
#[command(
    name = "spark-updater",
    version,
    about = "Signed staged update, health check, and rollback"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Verify a release manifest against the installed trust root.
    Verify {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long, default_value = DEFAULT_TRUST_ROOT)]
        trust_root: PathBuf,
    },

    /// Run the post-install health gate (§45.2 step 13).
    Health {
        #[arg(long, default_value = DEFAULT_DATA_DIR)]
        data_dir: PathBuf,
        #[arg(long)]
        identity_credentials: Option<PathBuf>,
        #[arg(long, default_value = DEFAULT_PRIVILEGED_SOCKET)]
        privileged_socket: PathBuf,
        /// Fail when the helper does not answer; leave optional while postinst is starting units.
        #[arg(long)]
        require_privileged_helper: bool,
    },

    /// Apply through privileged re-verification and dpkg; commit only after postinst health checks, otherwise restore the previous package.
    Apply {
        /// The signed release manifest.
        #[arg(long)]
        manifest: PathBuf,
        /// The release artifact (`.deb`).
        #[arg(long)]
        package: PathBuf,
        /// Detached signature over the artifact bytes.
        #[arg(long)]
        signature: PathBuf,
        /// Explicit release id; defaults to `<channel>-<version>`.
        #[arg(long)]
        release_id: Option<String>,
        /// Installed release trust root.
        #[arg(long, default_value = DEFAULT_TRUST_ROOT)]
        trust_root: PathBuf,
        /// Privileged helper socket.
        #[arg(long, default_value = DEFAULT_PRIVILEGED_SOCKET)]
        privileged_socket: PathBuf,
    },

    /// Execute a previously accepted release only from the root-owned systemd worker template.
    #[command(hide = true)]
    Worker {
        #[arg(long)]
        release_id: String,
    },

    /// Run fixed package/firmware updates in the helper-started root unit and record the private outcome.
    #[command(hide = true)]
    OsUpdate {
        #[arg(long)]
        job_id: String,
        #[arg(long)]
        system_packages: bool,
        #[arg(long)]
        firmware: bool,
        #[arg(long, default_value = spark_updater::os_update::DEFAULT_STATE_ROOT)]
        state_root: PathBuf,
    },
}

fn main() -> ExitCode {
    match run() {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("spark-updater: {message}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<String, String> {
    let cli = Cli::parse();
    match cli.command {
        Command::Verify {
            manifest,
            trust_root,
        } => {
            let root = ReleaseTrustRoot::load(&trust_root).map_err(|error| error.to_string())?;
            let bytes = std::fs::read(&manifest)
                .map_err(|error| format!("failed to read {}: {error}", manifest.display()))?;
            let verified = root
                .verify_manifest(&bytes, time::OffsetDateTime::now_utc())
                .map_err(|error| error.to_string())?;
            Ok(serde_json::json!({
                "version": verified.manifest.version,
                "channel": verified.manifest.channel,
                "key_id": verified.key_id,
                "artifacts": verified.manifest.artifacts.len(),
            })
            .to_string())
        }

        Command::Health {
            data_dir,
            identity_credentials,
            privileged_socket,
            require_privileged_helper,
        } => {
            let report = health::run_health_gate_with_credentials(
                &data_dir,
                &privileged_socket,
                require_privileged_helper,
                identity_credentials.as_deref(),
            );
            let json = serde_json::to_string(&report).map_err(|error| error.to_string())?;
            if report.healthy {
                Ok(json)
            } else {
                Err(format!("UPDATE_HEALTH_CHECK_FAILED {json}"))
            }
        }

        Command::Apply {
            manifest,
            package,
            signature,
            release_id,
            trust_root,
            privileged_socket,
        } => {
            let value = apply::run_apply(&apply::ApplyRequest {
                manifest_path: &manifest,
                package_path: &package,
                signature_path: &signature,
                trust_root: &trust_root,
                release_id: release_id.as_deref(),
                staging_root: Path::new(apply::DEFAULT_STAGING_ROOT),
                privileged_socket: &privileged_socket,
            })
            .map_err(|error| error.to_string())?;
            Ok(value.to_string())
        }

        Command::OsUpdate {
            job_id,
            system_packages,
            firmware,
            state_root,
        } => {
            if !nix::unistd::geteuid().is_root() {
                return Err(
                    "UPDATE_WORKER_NOT_ROOT the detached OS update worker must run as root".into(),
                );
            }
            let outcome = spark_updater::os_update::run(
                &job_id,
                system_packages,
                firmware,
                &spark_privd::update::SystemCommandRunner,
                &state_root,
            )?;
            let json = serde_json::to_string(&outcome).map_err(|error| error.to_string())?;
            if outcome.succeeded() {
                Ok(json)
            } else {
                Err(json)
            }
        }
        Command::Worker { release_id } => {
            if !nix::unistd::geteuid().is_root() {
                return Err(
                    "UPDATE_WORKER_NOT_ROOT the detached update worker must run as root".into(),
                );
            }
            let service_user = nix::unistd::User::from_name("sparkd")
                .map_err(|error| format!("failed to resolve sparkd service account: {error}"))?
                .ok_or_else(|| "sparkd service account is missing".to_owned())?;
            let outcome =
                spark_privd::update::RuntimeUpdateDirector::new(service_user.uid.as_raw())
                    .apply_scheduled(&release_id)
                    .map_err(|error| error.to_string())?;
            let json = serde_json::to_string(&outcome).map_err(|error| error.to_string())?;
            if outcome.accepted() {
                Ok(json)
            } else {
                Err(json)
            }
        }
    }
}
