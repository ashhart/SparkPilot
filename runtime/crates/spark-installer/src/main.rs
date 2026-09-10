//! Expose bounded noninteractive installer commands: one success JSON object or a nonzero plain-text error, with no passwords, fetch URLs or shell fragments.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use spark_installer::trust::ReleaseTrustRoot;
use spark_installer::verify;
use spark_installer::{bootstrap, state::custody};

/// Default node data directory (§22).
const DEFAULT_DATA_DIR: &str = "/var/lib/spark-runtime";

#[derive(Debug, Parser)]
#[command(
    name = "spark-installer",
    version,
    about = "Spark Runtime install-time operations"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Atomically preserve existing node authority under root custody while services are stopped.
    PrepareIdentity,
    /// Remove obsolete service-owned private key names after the new service passes health checks.
    CompleteIdentityMigration,
    /// Explicitly restore legacy custody for an administrator-requested rollback while services are stopped.
    RestoreLegacyIdentity,
    /// Create the node identity if absent and migrate the database.
    Prepare {
        #[arg(long, default_value = DEFAULT_DATA_DIR)]
        data_dir: PathBuf,
        #[arg(long, default_value = "Spark")]
        node_name: String,
        /// Bypass the version preflight for a rollback package; migration compatibility is still required.
        #[arg(long)]
        allow_downgrade: bool,
    },

    /// Prepare state directories as root without resolving service-controlled paths.
    PrepareState {
        #[arg(long, default_value = "sparkd")]
        user: String,
        #[arg(long, default_value = "sparkd")]
        group: String,
    },

    /// Seed the signed bootstrap catalogue once and preserve existing live catalogues on upgrades or reinstalls.
    SeedCatalogue {
        #[arg(long, default_value = "sparkd")]
        user: String,
        #[arg(long, default_value = "sparkd")]
        group: String,
    },

    /// Restore database/configuration from an upgrade snapshot without resolving service-controlled paths.
    RestoreState {
        #[arg(long)]
        backup: PathBuf,
        #[arg(long, default_value = DEFAULT_DATA_DIR)]
        data_dir: PathBuf,
        #[arg(long, default_value = "/etc/spark-runtime")]
        conf_dir: PathBuf,
        #[arg(long, default_value = "sparkd")]
        user: String,
        #[arg(long, default_value = "sparkd")]
        group: String,
    },

    /// Report the database schema version without changing anything.
    Schema {
        #[arg(long, default_value = DEFAULT_DATA_DIR)]
        data_dir: PathBuf,
    },

    /// Mint the single-use first-owner pairing invitation.
    BootstrapOwner {
        #[arg(long, default_value = DEFAULT_DATA_DIR)]
        data_dir: PathBuf,
        #[arg(long, default_value_t = bootstrap::OWNER_INVITATION_SECONDS)]
        expires_in_seconds: i64,
    },

    /// Require manifest signature, artifact digest and detached artifact signature; verification cannot be disabled.
    VerifyPackage {
        /// The `.deb` to check.
        #[arg(long)]
        package: PathBuf,
        /// Detached signature over the package bytes.
        #[arg(long)]
        signature: PathBuf,
        /// The release manifest that names it.
        #[arg(long)]
        manifest: PathBuf,
        /// Use installer-supplied trust only when the Spark has no installed root.
        #[arg(long)]
        trust_root: PathBuf,
        /// Prefer the installed root because the installing machine did not choose it for this request.
        #[arg(long, default_value = spark_installer::trust::INSTALLED_TRUST_ROOT)]
        installed_trust_root: PathBuf,
        /// Artifact name, required when the manifest lists more than one.
        #[arg(long)]
        artifact: Option<String>,
    },
}

fn main() -> ExitCode {
    match run() {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("spark-installer: {message}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<String, String> {
    let cli = Cli::parse();
    let value = match cli.command {
        Command::RestoreLegacyIdentity => {
            serde_json::to_value(custody::restore_legacy_identity().map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?
        }
        Command::PrepareIdentity => {
            serde_json::to_value(custody::prepare_identity().map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?
        }
        Command::CompleteIdentityMigration => {
            serde_json::to_value(custody::complete_identity_migration().map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?
        }
        Command::Prepare {
            data_dir,
            node_name,
            allow_downgrade,
        } => {
            let report = if data_dir == std::path::Path::new(DEFAULT_DATA_DIR)
                && std::fs::symlink_metadata(custody::INSTALLED_IDENTITY).is_ok()
            {
                let identity = custody::installed_identity().map_err(|e| e.to_string())?;
                custody::drop_to_service().map_err(|e| e.to_string())?;
                bootstrap::prepare_with_identity(&data_dir, identity, false, allow_downgrade)
            } else {
                if data_dir == std::path::Path::new(DEFAULT_DATA_DIR)
                    && unsafe { libc::geteuid() } == 0
                {
                    custody::drop_to_service().map_err(|e| e.to_string())?;
                }
                bootstrap::prepare(&data_dir, &node_name, allow_downgrade)
            }
            .map_err(|error| error.to_string())?;
            serde_json::to_value(report).map_err(|error| error.to_string())?
        }

        Command::PrepareState { user, group } => {
            let report =
                spark_installer::state::prepare(&user, &group).map_err(|e| e.to_string())?;
            serde_json::to_value(report).map_err(|error| error.to_string())?
        }

        Command::SeedCatalogue { user, group } => {
            let report = spark_installer::state::seed_catalogue(&user, &group)
                .map_err(|error| error.to_string())?;
            serde_json::to_value(report).map_err(|error| error.to_string())?
        }

        Command::RestoreState {
            backup,
            data_dir,
            conf_dir,
            user,
            group,
        } => {
            let report =
                spark_installer::state::restore(&backup, &data_dir, &conf_dir, &user, &group)
                    .map_err(|e| e.to_string())?;
            serde_json::to_value(report).map_err(|error| error.to_string())?
        }

        Command::Schema { data_dir } => {
            let report = bootstrap::schema_report(&data_dir).map_err(|e| e.to_string())?;
            serde_json::to_value(report).map_err(|error| error.to_string())?
        }

        Command::BootstrapOwner {
            data_dir,
            expires_in_seconds,
        } => {
            let report = if data_dir == std::path::Path::new(DEFAULT_DATA_DIR) {
                let identity = custody::installed_identity().map_err(|e| e.to_string())?;
                let fingerprint = sparkd::tls::fingerprint_at(
                    &PathBuf::from(custody::INSTALLED_IDENTITY).join("node.crt"),
                )
                .map_err(|e| e.to_string())?;
                custody::drop_to_service().map_err(|e| e.to_string())?;
                bootstrap::bootstrap_owner_with_identity(
                    &data_dir,
                    expires_in_seconds,
                    identity,
                    fingerprint,
                )
            } else {
                bootstrap::bootstrap_owner(&data_dir, expires_in_seconds)
            }
            .map_err(|error| error.to_string())?;
            serde_json::to_value(report).map_err(|error| error.to_string())?
        }

        Command::VerifyPackage {
            package,
            signature,
            manifest,
            trust_root,
            installed_trust_root,
            artifact,
        } => {
            let now = time::OffsetDateTime::now_utc();

            // Prefer installed trust, fall back only on first install, and report the selected source.
            let (root, source) = if installed_trust_root.is_file() {
                (
                    ReleaseTrustRoot::load(&installed_trust_root)
                        .map_err(|error| error.to_string())?,
                    verify::TrustRootSource::Installed,
                )
            } else {
                (
                    ReleaseTrustRoot::load(&trust_root).map_err(|error| error.to_string())?,
                    verify::TrustRootSource::Supplied,
                )
            };

            let manifest_bytes = std::fs::read(&manifest)
                .map_err(|error| format!("failed to read {}: {error}", manifest.display()))?;

            // Verify manifest authority before trusting any contained artifact digest.
            let verified = root
                .verify_manifest(&manifest_bytes, now)
                .map_err(|error| error.to_string())?;
            let entry = verified
                .manifest
                .artifact(artifact.as_deref())
                .map_err(|error| error.to_string())?;

            let signature_bytes =
                verify::read_signature(&signature).map_err(|error| error.to_string())?;

            let report = verify::verify_artifact(
                &package,
                &verify::ArtifactVerification {
                    artifact: entry,
                    channel: &verified.manifest.channel,
                    trust_root: &root,
                    trust_root_source: source,
                    signature: &signature_bytes,
                    key_id: &verified.key_id,
                    at: now,
                },
            )
            .map_err(|error| error.to_string())?;

            let mut value = serde_json::to_value(report).map_err(|error| error.to_string())?;
            value["manifest_key_id"] = serde_json::Value::String(verified.key_id);
            value["version"] = serde_json::Value::String(verified.manifest.version.clone());
            value["channel"] = serde_json::Value::String(verified.manifest.channel.clone());
            value
        }
    };
    serde_json::to_string(&value).map_err(|error| error.to_string())
}
