//! Compose shared application services with trait boundaries for deterministic hardware/process tests.

mod recovery;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use parking_lot::Mutex;
use rusqlite::Connection;
use spark_core::identity::NodeIdentity;
use spark_telemetry::SystemMonitor;

use crate::agent::AgentService;
use crate::appliance_api::{
    ApplianceStatusProvider, TelemetryConsentConfig, default_appliance_status_provider,
    persisted_telemetry_consent,
};
use crate::catalogue_api::CatalogueRefreshService;
use crate::clock::{UtcClock, system_clock};
use crate::cluster::ClusterService;
use crate::cluster_coordination::ClusterCoordinationService;
use crate::download::DownloadCoordinator;
use crate::engine::EngineManager;
use crate::events::EventBus;
use crate::fabric::{FabricStatusProvider, SysfsFabricStatusProvider};
use crate::guard::MemoryGuardService;
use crate::idempotency::IdempotencyService;
use crate::inference_metrics::InferenceMetricsCollector;
use crate::jobs::JobService;
use crate::models::{LiveModelInventory, ModelInventory};
use crate::network_api::{NetworkStatusProvider, default_network_status_provider};
use crate::preview::PreviewService;
use crate::privd::PrivilegedClient;
use crate::project::ProjectManager;
use crate::remote::RemoteAccessService;

#[derive(Debug, Clone)]
pub struct RuntimeConfig {
    pub api_major: u32,
    pub runtime_version: String,
    pub listen: SocketAddr,
    pub node_name: String,
    pub data_dir: PathBuf,
    pub advertise: bool,
    pub tls: bool,
}

#[derive(Debug, Clone)]
pub struct StoragePaths {
    pub models: PathBuf,
    pub downloads: PathBuf,
}

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<RuntimeConfig>,
    pub storage: Arc<StoragePaths>,
    pub identity: Arc<NodeIdentity>,
    pub telemetry: Arc<dyn SystemMonitor>,
    /// Bounded loopback-only inference metrics and its in-memory rate cache.
    pub inference_metrics: Arc<InferenceMetricsCollector>,
    pub request_history: Arc<crate::request_history::RequestHistoryService>,
    /// Read-only NetworkManager inventory and bounded reachability checks.
    pub network_status: Arc<dyn NetworkStatusProvider>,
    /// Read-only ConnectX, address, route, and Netplan provenance inventory.
    pub fabric_status: Arc<dyn FabricStatusProvider>,
    /// Read-only host capability and status probes for settings.
    pub appliance: Arc<dyn ApplianceStatusProvider>,
    /// Use the fixed production release handoff cache, with isolated directory injection for tests.
    pub runtime_update_staging_root: Arc<PathBuf>,
    /// Live, device-local consent controlling optional telemetry retention.
    pub telemetry_consent: Arc<parking_lot::RwLock<TelemetryConsentConfig>>,
    /// Live gate for retaining detailed, local-only diagnostic samples.
    pub technical_diagnostics: Arc<AtomicBool>,
    /// Report availability only when both optional-service loopback and pinned-access listeners were reserved during startup.
    pub optional_services_available: Arc<AtomicBool>,
    pub open_webui_upstream_port: Arc<std::sync::atomic::AtomicU16>,
    /// Package-installed signed recipe and its dedicated verification root.
    pub optional_service_recipe_path: Arc<PathBuf>,
    pub optional_service_root_key_path: Arc<PathBuf>,
    /// Shared UTC source for persisted timestamps.
    pub clock: Arc<dyn UtcClock>,
    /// Share the WAL-mode SQLite connection after startup migrations.
    pub database: Option<Arc<Mutex<Connection>>>,
    /// Use typed privileged transport, with a test socket injected through with_privileged_client.
    pub privileged: Option<PrivilegedClient>,
    /// Signed model catalogue and installed inventory.
    pub models: Option<Arc<LiveModelInventory>>,
    /// Device-local signed catalogue promotion and retained rollback state.
    pub catalogue_refresh: Option<Arc<CatalogueRefreshService>>,
    /// Durable operations with leases and recovery.
    pub jobs: JobService,
    /// Owner-reviewed daemon-owned scheduled model preparation.
    pub warmups: crate::warmup::WarmupService,
    /// Recurring owner automations fired on the daemon clock.
    pub automations: crate::automations::scheduler::AutomationService,
    /// Atomic request replay and response persistence for mutations.
    pub idempotency: IdempotencyService,
    /// Short-lived digest bindings for consequential model mutations.
    pub previews: PreviewService,
    /// Live event fan-out.
    pub events: EventBus,
    /// §60.3: per-class event retention applied by the housekeeping sweep.
    pub event_retention: crate::events::EventRetention,
    /// §34.4: days of aggregated usage kept; 0 keeps it indefinitely.
    pub usage_retention_days: u64,
    /// Model download engine.
    pub download: DownloadHolder,
    /// Memory guard; absent in tests that do not exercise it.
    pub guard: Option<Arc<MemoryGuardService>>,
    /// Remote access service.
    pub remote: Option<Arc<RemoteAccessService>>,
    /// Network status and configuration (§25.5).
    pub network: Option<Arc<crate::network::NetworkService>>,
    /// Cluster membership and lifecycle service.
    pub cluster: Option<Arc<ClusterService>>,
    /// Multi-member prepare/commit/rollback and worker-loss coordinator.
    pub cluster_coordination: Option<Arc<ClusterCoordinationService>>,
    /// Build submission and worker coordination.
    pub builds: BuildHolder,
    /// Engine lifecycle manager.
    pub engine: EngineHolder,
    /// Independent-request pool admission, separate from distributed clusters.
    pub pools: Arc<crate::pool::PoolService>,
    pub router_identity: Arc<crate::pool_router_identity::RouterIdentityService>,
    /// Project runtime manager.
    pub projects: ProjectHolder,
    /// Coding-agent runtime.
    pub agents: AgentHolder,
    /// Pin SHA-256 of the exact TLS leaf DER separately from the Ed25519 pairing authority fingerprint.
    pub tls_fingerprint: Option<String>,
    /// Live guest requests, so one guest's concurrency limit is enforced across its own streams.
    pub guest_concurrency: crate::guest::GuestConcurrency,
    /// Let authz evaluate optional capability deployment policy rather than reading it directly in handlers.
    pub capability_policy: crate::capability::CapabilityPolicy,
    /// Per-principal and per-source request budgets (§16.4).
    pub rate_limiter: crate::ratelimit::RateLimiter,
    /// Freshness window for `X-Spark-User-Presence` proofs (§58.3).
    pub presence_freshness_seconds: i64,
    /// Free disk kept after a model install (§30.4).
    pub disk_reserve_bytes: u64,
}

/// Owned holder for the coding-agent wiring.
#[derive(Clone)]
pub struct AgentHolder {
    pub manager: Option<Arc<AgentService>>,
    /// Advertise agent execution only with a real model-backed planner, not review support or a scripted test brain.
    pub execution_available: bool,
}

/// Owned holder for the project runtime wiring.
#[derive(Clone)]
pub struct ProjectHolder {
    pub manager: Option<Arc<ProjectManager>>,
    /// Image and coding-agent preparation shared by the owner route and boot.
    pub preparation: Arc<crate::project_api::development_prepare::DevelopmentPreparation>,
}

/// Owned build-service holder.
#[derive(Clone)]
pub struct BuildHolder {
    pub service: Option<Arc<crate::build::BuildService>>,
}

/// Owned holder for the engine lifecycle wiring.
#[derive(Clone)]
pub struct EngineHolder {
    pub manager: Option<Arc<EngineManager>>,
}

/// Owned holder for the download engine wiring.
#[derive(Clone)]
pub struct DownloadHolder {
    pub coordinator: Option<Arc<DownloadCoordinator>>,
}

impl AppState {
    pub fn new(
        config: RuntimeConfig,
        identity: NodeIdentity,
        telemetry: Arc<dyn SystemMonitor>,
        database: Option<Connection>,
    ) -> Self {
        Self::new_with_clock(config, identity, telemetry, database, system_clock())
    }

    /// Construct core services with one clock before dependent services retain shared job/event handles.
    pub fn new_with_clock(
        config: RuntimeConfig,
        identity: NodeIdentity,
        telemetry: Arc<dyn SystemMonitor>,
        database: Option<Connection>,
        clock: Arc<dyn UtcClock>,
    ) -> Self {
        if let Some(conn) = &database
            && crate::request_history::recover(conn, clock.now().unix_timestamp()).is_err()
        {
            tracing::warn!("request history restart reconciliation unavailable");
        }
        let storage = StoragePaths {
            models: config.data_dir.join("models"),
            downloads: config.data_dir.join("downloads"),
        };
        let router_identity = Arc::new(crate::pool_router_identity::RouterIdentityService::new(
            config.data_dir.join("router-identity"),
        ));
        // §60.1: the operation family needs the node identity before the services that publish it exist.
        let node_id = identity.node_id().to_string();
        let events = EventBus::with_clock(clock.clone());
        Self {
            router_identity,
            config: Arc::new(config),
            storage: Arc::new(storage),
            identity: Arc::new(identity),
            telemetry,
            inference_metrics: Arc::new(InferenceMetricsCollector::default()),
            request_history: Arc::new(crate::request_history::RequestHistoryService::default()),
            network_status: default_network_status_provider(),
            fabric_status: Arc::new(SysfsFabricStatusProvider::default()),
            appliance: default_appliance_status_provider(),
            runtime_update_staging_root: Arc::new(PathBuf::from(
                spark_privd::update::DEFAULT_STAGING_ROOT,
            )),
            telemetry_consent: Arc::new(
                parking_lot::RwLock::new(TelemetryConsentConfig::default()),
            ),
            technical_diagnostics: Arc::new(AtomicBool::new(false)),
            optional_services_available: Arc::new(AtomicBool::new(false)),
            open_webui_upstream_port: Arc::new(std::sync::atomic::AtomicU16::new(0)),
            optional_service_recipe_path: Arc::new(PathBuf::from(
                spark_models::service_recipe::DEFAULT_OPEN_WEBUI_RECIPE_PATH,
            )),
            optional_service_root_key_path: Arc::new(PathBuf::from(
                spark_models::service_recipe::DEFAULT_SERVICE_ROOT_PATH,
            )),
            clock: clock.clone(),
            database: database.map(|conn| Arc::new(Mutex::new(conn))),
            privileged: None,
            models: None,
            catalogue_refresh: None,
            jobs: JobService::with_clock(clock.clone()).with_events(events.clone(), &node_id),
            warmups: crate::warmup::WarmupService::default(),
            automations: crate::automations::scheduler::AutomationService::default(),
            idempotency: IdempotencyService::new(clock.clone()),
            previews: PreviewService::new(clock.clone()),
            events,
            event_retention: crate::events::EventRetention::default(),
            usage_retention_days: crate::settings::DEFAULT_USAGE_RETENTION_DAYS,
            download: DownloadHolder { coordinator: None },
            guard: None,
            remote: None,
            network: None,
            cluster: None,
            cluster_coordination: None,
            builds: BuildHolder { service: None },
            engine: EngineHolder { manager: None },
            pools: Arc::new(crate::pool::PoolService::default()),
            projects: ProjectHolder {
                manager: None,
                preparation: Arc::default(),
            },
            agents: AgentHolder {
                manager: None,
                execution_available: false,
            },
            tls_fingerprint: None,
            guest_concurrency: crate::guest::GuestConcurrency::new(),
            capability_policy: crate::capability::CapabilityPolicy::default(),
            rate_limiter: crate::ratelimit::RateLimiter::new(clock),
            presence_freshness_seconds: crate::presence::DEFAULT_FRESHNESS_SECONDS,
            disk_reserve_bytes: crate::download::DEFAULT_DISK_RESERVE_BYTES,
        }
    }

    pub fn with_storage_paths(
        mut self,
        models: impl Into<PathBuf>,
        downloads: impl Into<PathBuf>,
    ) -> Self {
        self.storage = Arc::new(StoragePaths {
            models: models.into(),
            downloads: downloads.into(),
        });
        self
    }

    pub fn with_disk_reserve(mut self, bytes: u64) -> Self {
        self.disk_reserve_bytes = bytes;
        self
    }

    /// Replace the appliance network reader with a deterministic provider.
    pub fn with_network_status_provider(
        mut self,
        provider: Arc<dyn NetworkStatusProvider>,
    ) -> Self {
        self.network_status = provider;
        self
    }

    pub fn with_fabric_status_provider(mut self, provider: Arc<dyn FabricStatusProvider>) -> Self {
        self.fabric_status = provider;
        self
    }

    pub fn with_appliance_status_provider(
        mut self,
        provider: Arc<dyn ApplianceStatusProvider>,
    ) -> Self {
        self.appliance = provider;
        self
    }

    pub fn with_runtime_update_staging_root(mut self, root: impl Into<PathBuf>) -> Self {
        self.runtime_update_staging_root = Arc::new(root.into());
        self
    }

    pub fn with_optional_services_available(self, available: bool) -> Self {
        self.optional_services_available
            .store(available, Ordering::SeqCst);
        self
    }

    pub fn with_optional_service_recipe_paths(
        mut self,
        recipe: impl Into<PathBuf>,
        root_key: impl Into<PathBuf>,
    ) -> Self {
        self.optional_service_recipe_path = Arc::new(recipe.into());
        self.optional_service_root_key_path = Arc::new(root_key.into());
        self
    }

    pub fn with_tls_fingerprint(mut self, fingerprint: impl Into<String>) -> Self {
        self.tls_fingerprint = Some(fingerprint.into());
        self
    }

    /// Attach the memory guard.
    pub fn with_guard(mut self, guard: Arc<MemoryGuardService>) -> Self {
        self.guard = Some(guard);
        self
    }

    /// Apply the configured retention windows rather than the defaults.
    pub fn with_usage_retention_days(mut self, days: u64) -> Self {
        self.usage_retention_days = days;
        self
    }

    pub fn with_event_retention(mut self, retention: crate::events::EventRetention) -> Self {
        self.event_retention = retention;
        self
    }

    /// Set lease cadence before dependent services clone the job service.
    pub fn with_operation_leases(mut self, lease: crate::jobs::LeaseConfig) -> Self {
        self.jobs = JobService::with_clock_and_lease(self.clock.clone(), lease)
            .with_events(self.events.clone(), &self.identity.node_id().to_string());
        self
    }

    /// Attach the network service (§25.5).
    pub fn with_network(mut self, network: Arc<crate::network::NetworkService>) -> Self {
        self.network = Some(network);
        self
    }

    /// Attach the remote access service.
    pub fn with_remote(mut self, remote: Arc<RemoteAccessService>) -> Self {
        self.remote = Some(remote);
        self
    }

    /// Attach the cluster service.
    pub fn with_cluster(mut self, cluster: Arc<ClusterService>) -> Self {
        self.cluster = Some(cluster);
        self
    }

    pub fn with_cluster_coordination(
        mut self,
        coordinator: Arc<ClusterCoordinationService>,
    ) -> Self {
        self.cluster_coordination = Some(coordinator);
        self
    }

    /// Attach the runner that performs automation runs against this Spark's own engine.
    pub fn with_automation_runner(
        mut self,
        runner: Arc<dyn crate::automations::scheduler::AutomationRunner>,
    ) -> Self {
        self.automations = crate::automations::scheduler::AutomationService::with_runner(runner);
        self
    }

    /// Attach the build service.
    pub fn with_builds(mut self, service: Arc<crate::build::BuildService>) -> Self {
        self.builds = BuildHolder {
            service: Some(service),
        };
        self
    }

    /// Attach the coding-agent service.
    pub fn with_agents(mut self, manager: Arc<AgentService>) -> Self {
        self.agents = AgentHolder {
            manager: Some(manager),
            execution_available: true,
        };
        self
    }

    /// Attach review support without advertising the scripted test planner as a working coding agent.
    pub fn with_review_only_agents(mut self, manager: Arc<AgentService>) -> Self {
        self.agents = AgentHolder {
            manager: Some(manager),
            execution_available: false,
        };
        self
    }

    /// Attach the project runtime manager.
    pub fn with_projects(mut self, manager: Arc<ProjectManager>) -> Self {
        self.projects.manager = Some(manager);
        self
    }

    /// Replace how the coding agent is cached, so tests never reach the network.
    pub fn with_development_preparation(
        mut self,
        preparation: Arc<crate::project_api::development_prepare::DevelopmentPreparation>,
    ) -> Self {
        self.projects.preparation = preparation;
        self
    }

    /// Attach the engine lifecycle manager.
    pub fn with_engine(mut self, manager: Arc<EngineManager>) -> Self {
        self.engine = EngineHolder {
            manager: Some(manager),
        };
        self
    }

    /// Reuse the existing database Arc when services such as the guard already hold it.
    pub fn with_database(mut self, database: Arc<Mutex<Connection>>) -> Self {
        if crate::request_history::recover(&database.lock(), self.clock.now().unix_timestamp())
            .is_err()
        {
            tracing::warn!("request history restart reconciliation unavailable");
        }
        let consent = persisted_telemetry_consent(&database.lock());
        self.technical_diagnostics
            .store(consent.technical, Ordering::Relaxed);
        *self.telemetry_consent.write() = consent;
        self.database = Some(database);
        self
    }

    /// Test/development override for optional local telemetry retention.
    pub fn with_telemetry_consent(self, consent: TelemetryConsentConfig) -> Self {
        self.technical_diagnostics
            .store(consent.technical, Ordering::Relaxed);
        *self.telemetry_consent.write() = consent;
        self
    }

    /// Attach the download engine.
    pub fn with_download(mut self, coordinator: DownloadCoordinator) -> Self {
        self.download = DownloadHolder {
            coordinator: Some(Arc::new(coordinator)),
        };
        self
    }

    /// Attach the model inventory.
    pub fn with_models(mut self, models: Arc<ModelInventory>) -> Self {
        self.models = Some(Arc::new(LiveModelInventory::new(models)));
        self
    }

    /// Reuse one live catalogue handle for atomic refresh and restart composition.
    pub fn with_live_models(mut self, models: Arc<LiveModelInventory>) -> Self {
        self.models = Some(models);
        self
    }

    pub fn with_catalogue_refresh(mut self, service: Arc<CatalogueRefreshService>) -> Self {
        self.catalogue_refresh = Some(service);
        self
    }

    /// Attach a privileged socket for local/embedded deployments.
    pub fn with_privileged_socket(mut self, client: PrivilegedClient) -> Self {
        self.privileged = Some(client);
        self
    }

    /// Close prior-process terminal rows because no local session remains attachable after restart.
    pub fn close_orphaned_terminals(&self) -> Result<usize, crate::store::StoreError> {
        let Some(database) = &self.database else {
            return Ok(0);
        };
        let conn = database.lock();
        crate::store::close_orphaned_terminals(&conn, &self.clock.now_rfc3339())
    }
}
