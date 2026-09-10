use super::*;

#[derive(Debug, Parser)]
#[command(name = "sparkd", about = "Spark Runtime control daemon")]
pub(super) struct Cli {
    /// Address to listen on; the product default is 0.0.0.0:7443.
    #[arg(long, default_value = "0.0.0.0:7443")]
    pub(super) listen: SocketAddr,

    /// Store identity/database in ./spark-runtime by default, or /var/lib/spark-runtime when running as root.
    #[arg(long)]
    pub(super) data_dir: Option<PathBuf>,

    /// Read immutable systemd credentials without creating or repairing persistent identity.
    #[arg(long, conflicts_with = "no_tls")]
    pub(super) identity_credentials: Option<PathBuf>,

    /// Human-readable node name.
    #[arg(long, default_value = "Spark")]
    pub(super) node_name: String,

    /// Allow plain HTTP for development only, without certificate creation or Bonjour unless advertise-insecure is explicitly enabled.
    #[arg(long)]
    pub(super) no_tls: bool,

    /// Advertise over Bonjour even without TLS. Development only.
    #[arg(long)]
    pub(super) advertise_insecure: bool,

    /// Do not advertise over Bonjour.
    #[arg(long)]
    pub(super) no_advertise: bool,

    /// Structured JSON logs.
    #[arg(long)]
    pub(super) json_logs: bool,

    /// Signed catalogue snapshot (requires --catalogue-root-key).
    #[arg(long)]
    pub(super) catalogue: Option<PathBuf>,

    /// Catalogue root public key (64 hex chars).
    #[arg(long)]
    pub(super) catalogue_root_key: Option<PathBuf>,

    /// Permit the advanced import-unverified flow (§29.5).
    #[arg(long)]
    pub(super) allow_unverified_import: bool,

    /// Load settings matching config/sparkd.example.toml, including memory_guard and telemetry policy.
    #[arg(long)]
    pub(super) config: Option<PathBuf>,

    /// Choose the privileged Docker product backend or the in-process loopback mock for development.
    #[arg(long, value_enum, default_value = "docker")]
    pub(super) engine_backend: EngineBackendChoice,

    /// Drain grace before an unload force-stops the engine (seconds).
    #[arg(long)]
    pub(super) drain_grace_secs: Option<u64>,

    /// Package-installed signed optional-service recipe.
    #[arg(
        long,
        default_value = spark_models::service_recipe::DEFAULT_OPEN_WEBUI_RECIPE_PATH
    )]
    pub(super) optional_service_recipe: PathBuf,

    /// Verification root for the package-installed optional-service recipe.
    #[arg(
        long,
        default_value = spark_models::service_recipe::DEFAULT_SERVICE_ROOT_PATH
    )]
    pub(super) optional_service_root_key: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, clap::ValueEnum)]
pub(super) enum EngineBackendChoice {
    Docker,
    Mock,
}

pub(super) fn default_data_dir() -> PathBuf {
    if geteuid().is_root() {
        PathBuf::from("/var/lib/spark-runtime")
    } else {
        PathBuf::from("./spark-runtime")
    }
}
