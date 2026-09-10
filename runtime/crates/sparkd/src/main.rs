//! `sparkd` binary: identity, migrations, TLS API server, Bonjour.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use clap::Parser;
use nix::unistd::geteuid;
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_telemetry::FakeSystemMonitor;
use spark_telemetry::ProcMonitor;
use sparkd::agent::AgentService;
use sparkd::bonjour;
use sparkd::build::BuildService;
use sparkd::cluster::ClusterService;
use sparkd::engine::EngineManager;
use sparkd::engine_backend::{DockerEngineBackend, MockVllmBackend};
use sparkd::guard::{GuardEngine, MemoryGuardService};
use sparkd::migration;
use sparkd::models::ModelInventory;
use sparkd::privd::PrivilegedClient;
use sparkd::project::ProjectManager;
use sparkd::remote::{PrivateOverlayProbe, RemoteAccessService, TailscaleOverlayProbe};
use sparkd::remote_overlay_setup::{
    PrivateOverlayProvisioner, PrivdOverlayProvisioner, ProvisionedOverlayProbe,
    UnavailableOverlayProvisioner,
};
use sparkd::route::router;
use sparkd::settings;
use sparkd::state::{AppState, RuntimeConfig};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();

    let filter =
        tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into());
    if cli.json_logs {
        tracing_subscriber::fmt()
            .with_env_filter(filter)
            .json()
            .init();
    } else {
        tracing_subscriber::fmt().with_env_filter(filter).init();
    }

    // Select the TLS provider explicitly so dependency feature order cannot change it.
    rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|e| format!("failed to install rustls crypto provider: {e:?}"))?;

    let data_dir = cli.data_dir.unwrap_or_else(default_data_dir);
    let identity = match &cli.identity_credentials {
        Some(directory) => spark_core::identity::credentials::load_credentials(directory)?,
        None => FileIdentityStore::new(data_dir.join("identity")).load_or_create(&cli.node_name)?,
    };
    tracing::info!(node_id = %identity.node_id(), "node identity ready");

    let tls_identity = if cli.no_tls {
        tracing::warn!(
            "--no-tls enables development-only plain HTTP; no certificate pin will be advertised"
        );
        None
    } else {
        let tls_identity = match &cli.identity_credentials {
            Some(directory) => sparkd::tls::load_credentials(directory)?,
            None => sparkd::tls::load_or_create(&data_dir.join("identity"))?,
        };
        tracing::info!(
            fingerprint = %tls_identity.fingerprint,
            created = tls_identity.created,
            "node TLS identity ready"
        );
        Some(tls_identity)
    };
    let tls_fingerprint = tls_identity
        .as_ref()
        .map(|identity| identity.fingerprint.clone());
    let optional_service_tls = tls_identity
        .as_ref()
        .map(sparkd::tls::NodeTlsIdentity::rustls_config);

    let settings = match &cli.config {
        Some(path) => {
            let loaded = settings::load(path)?;
            tracing::info!(path = %path.display(), "settings loaded");
            loaded
        }
        None => settings::Settings::default(),
    };
    let event_retention = settings.event_retention();

    let conn = startup_database::open(&data_dir, &event_retention)?;
    let models_dir = settings
        .models
        .models_dir
        .clone()
        .unwrap_or_else(|| data_dir.join("models"));
    let downloads_dir = settings
        .models
        .downloads_dir
        .clone()
        .unwrap_or_else(|| data_dir.join("downloads"));
    let catalogue_path = cli
        .catalogue
        .as_deref()
        .or(settings.models.catalogue_path.as_deref());
    let catalogue_root_key_path = cli
        .catalogue_root_key
        .as_deref()
        .or(settings.models.catalogue_root_key_path.as_deref());
    if let Some(path) = catalogue_path {
        let recovered = sparkd::catalogue_api::recover_interrupted_promotion(path)
            .map_err(|error| format!("catalogue recovery: {error}"))?;
        if recovered {
            tracing::warn!(path = %path.display(), "restored the retained catalogue after an interrupted promotion");
        }
    }
    let drain_grace_seconds = cli
        .drain_grace_secs
        .or(settings.models.drain_timeout_seconds)
        .unwrap_or(30);
    // Allow fifteen minutes for first-load checkpoint reads, kernel compilation and warmup on Spark hardware.
    let health_check_timeout_seconds = settings.models.health_check_timeout_seconds.unwrap_or(900);
    let memory_recovery_timeout_seconds = settings
        .models
        .unload_memory_recovery_timeout_seconds
        .unwrap_or(60);
    let minimum_system_reserve_bytes = settings.models.minimum_system_reserve_bytes.unwrap_or(0);
    let disk_reserve_bytes = settings
        .models
        .minimum_free_disk_bytes
        .unwrap_or(sparkd::download::DEFAULT_DISK_RESERVE_BYTES);

    // Use real procfs readings on appliances and deterministic reference values for macOS development.
    let (monitor, memory_source): (
        Arc<dyn spark_telemetry::SystemMonitor>,
        Arc<dyn spark_telemetry::MemorySource>,
    ) = match ProcMonitor::new("/proc", data_dir.clone()) {
        Some(proc_monitor) => {
            let proc_monitor = Arc::new(proc_monitor);
            let source: Arc<dyn spark_telemetry::MemorySource> = proc_monitor.clone();
            (proc_monitor, source)
        }
        None => {
            tracing::info!("procfs unavailable; using reference telemetry values");
            (Arc::new(FakeSystemMonitor), Arc::new(ReferenceSignals))
        }
    };

    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: spark_core::runtime_version::installed_runtime_version(),
        listen: cli.listen,
        node_name: cli.node_name.clone(),
        data_dir: data_dir.clone(),
        advertise: !cli.no_advertise,
        tls: !cli.no_tls,
    };
    // Fall back to the immutable packaged catalogue when older configurations lack its path setting.
    let bootstrap_catalogue_path = settings
        .models
        .bootstrap_catalogue_path
        .clone()
        .or_else(|| {
            catalogue_root_key_path
                .and_then(|root| root.parent()?.parent())
                .map(|share| share.join("catalog").join("bootstrap.json"))
        });
    let inventory = ModelInventory::from_catalogue(
        catalogue_path,
        catalogue_root_key_path,
        bootstrap_catalogue_path.as_deref(),
        cli.allow_unverified_import,
    )?;
    if !inventory.recipes.is_empty() {
        inventory
            .materialize(&conn)
            .map_err(|e| format!("catalogue materialise: {e}"))?;
        tracing::info!(models = inventory.recipes.len(), "model catalogue loaded");
    }
    let database = Arc::new(parking_lot::Mutex::new(conn));
    let privileged_client = match cli.engine_backend {
        EngineBackendChoice::Docker => Some(PrivilegedClient::default_socket()),
        EngineBackendChoice::Mock => None,
    };

    let mut state = AppState::new(config.clone(), identity, monitor.clone(), None)
        .with_storage_paths(models_dir.clone(), downloads_dir)
        .with_disk_reserve(disk_reserve_bytes)
        .with_operation_leases(settings.operations.lease_config())
        .with_event_retention(event_retention)
        .with_usage_retention_days(settings.telemetry.usage_retention_days.unwrap_or(90))
        .with_models(inventory)
        .with_download(sparkd::download_http::production_coordinator())
        .with_optional_service_recipe_paths(
            cli.optional_service_recipe.clone(),
            cli.optional_service_root_key.clone(),
        )
        .with_database(database.clone());
    if let Some(client) = privileged_client.clone() {
        state = state.with_privileged_socket(client);
    }
    if let Some(fingerprint) = tls_fingerprint.clone() {
        state = state.with_tls_fingerprint(fingerprint);
    }
    if let (Some(path), Some(root_path), Some(models)) = (
        catalogue_path,
        catalogue_root_key_path,
        state.models.clone(),
    ) {
        let root = sparkd::models::load_root_key(root_path)
            .map_err(|error| format!("catalogue refresh root: {error}"))?;
        let service = Arc::new(sparkd::catalogue_api::CatalogueRefreshService::new(
            path,
            root,
            models,
            database.clone(),
        )?);
        state = state.with_catalogue_refresh(service);
    }
    // With a privileged helper the overlay is set up and named through it; without one only detection remains.
    let overlay_provisioner: Arc<dyn PrivateOverlayProvisioner> = match privileged_client.clone() {
        Some(client) => Arc::new(PrivdOverlayProvisioner::new(client)),
        None => Arc::new(UnavailableOverlayProvisioner),
    };
    let overlay_probe: Arc<dyn PrivateOverlayProbe> = if privileged_client.is_some() {
        Arc::new(ProvisionedOverlayProbe::new(
            overlay_provisioner.clone(),
            cli.listen.port(),
        ))
    } else {
        Arc::new(TailscaleOverlayProbe::new(cli.listen.port()))
    };
    let remote = Arc::new(
        RemoteAccessService::new(
            database.clone(),
            state.events.clone(),
            state.identity.node_id().to_string(),
        )
        .with_private_overlay_probe(overlay_probe)
        .with_private_overlay_provisioner(overlay_provisioner),
    );
    // Discover and validate local ConnectX interfaces, then run pinned collective checks through the helper.
    let cluster = Arc::new(ClusterService::new(
        database.clone(),
        state.events.clone(),
        state.identity.node_id().to_string(),
        Arc::new(sparkd::cluster_link::SysfsLinkProbe::default()),
        Arc::new(sparkd::cluster_link::PrivilegedCollectiveTest::new(
            PrivilegedClient::default_socket(),
            settings.cluster.collective_image_digest.clone(),
        )),
    ));
    let cluster_coordination = Arc::new(
        sparkd::cluster_coordination::ClusterCoordinationService::new(
            database.clone(),
            state.identity.clone(),
            Arc::new(sparkd::cluster_coordination::PrivilegedClusterLink::new(
                PrivilegedClient::default_socket(),
            )),
            Arc::new(
                sparkd::cluster_coordination::PrivilegedDistributedRuntime::new(
                    PrivilegedClient::default_socket(),
                ),
            ),
        )
        .with_collective(Arc::new(
            sparkd::cluster_coordination::PrivilegedClusterCollective::new(
                PrivilegedClient::default_socket(),
            ),
        ))
        .with_peer_authenticator(Arc::new(
            sparkd::cluster_coordination::TcpClusterPeerAuthenticator::default(),
        ))
        .with_events(state.events.clone())
        .with_runtime_version(config.runtime_version.clone())
        .with_engine_image(settings.cluster.collective_image_digest.clone()),
    );

    // Read network facts without privilege and send mutations only as typed helper operations.
    let network = Arc::new(sparkd::network::NetworkService::production(
        PrivilegedClient::default_socket(),
    ));

    state = state
        .with_remote(remote)
        .with_network(network)
        .with_cluster(cluster)
        .with_cluster_coordination(cluster_coordination.clone());
    cluster_monitor::spawn(cluster_coordination.clone());

    // Wire durable single-engine loading, draining and unloading through the selected loopback backend.
    let engine_backend: Arc<dyn sparkd::engine::EngineBackend> = match cli.engine_backend {
        EngineBackendChoice::Docker => Arc::new(DockerEngineBackend::new(
            privileged_client
                .clone()
                .expect("Docker backend configures the privileged client"),
        )),
        EngineBackendChoice::Mock => Arc::new(MockVllmBackend::new()),
    };
    let engine = Arc::new(
        EngineManager::new(
            engine_backend,
            state.jobs.clone(),
            state.events.clone(),
            state.identity.node_id().to_string(),
            monitor.clone(),
            database.clone(),
            models_dir,
            tokio::time::Duration::from_secs(drain_grace_seconds),
            None,
        )
        .with_model_policy(
            minimum_system_reserve_bytes,
            tokio::time::Duration::from_secs(health_check_timeout_seconds),
            tokio::time::Duration::from_secs(memory_recovery_timeout_seconds),
        ),
    );
    let reconciled_engines = engine
        .reconcile_startup_with_inventory(
            &state
                .models
                .as_ref()
                .expect("model inventory configured")
                .snapshot(),
        )
        .await
        .map_err(|error| std::io::Error::other(error.message()))?;
    if reconciled_engines > 0 {
        tracing::warn!(
            reconciled_engines,
            "reconciled inference ownership left by an earlier daemon process"
        );
    }
    let state = state.with_engine(engine.clone());

    // Publish memory-guard engine actions through the same event bus used by SSE.
    let memory_guard_policy =
        sparkd::appliance_api::persisted_memory_policy(&database.lock(), settings.memory_guard);
    let guard = Arc::new(
        MemoryGuardService::with_database(
            memory_guard_policy,
            memory_source,
            Arc::new(GuardEngine::new(engine.clone())),
            state.events.clone(),
            database.clone(),
        )
        .with_thermal_policy(settings.thermal_guard)
        .with_technical_diagnostics(state.technical_diagnostics.clone()),
    );
    engine.set_guard(guard.clone());
    let state = state.with_guard(guard.clone());

    // Sample one guard state for consistent events and status readings.
    guard.spawn(state.identity.node_id().to_string(), monitor.clone());

    // Compose production terminals with privileged container execution only; release packaging does not enable the host-PTY feature.
    let project_manager = Arc::new(ProjectManager::new(
        Arc::new(spark_project_runner::CommandGit::new("git")),
        if cli.engine_backend == EngineBackendChoice::Mock {
            Arc::new(spark_project_runner::FakeContainerBoundary::default())
        } else {
            Arc::new(sparkd::project::PrivilegedContainer::new(
                privileged_client
                    .clone()
                    .expect("Docker backend configures the privileged client"),
            ))
        },
        Arc::new(sparkd::project::PrivilegedPtyRunner::new(
            PrivilegedClient::default_socket(),
        )),
        database.clone(),
        state.jobs.clone(),
        state.events.clone(),
        state.identity.node_id().to_string(),
        data_dir.join("projects"),
        data_dir.join("worktrees"),
    ));
    let state = state.with_projects(project_manager.clone());

    // Expose review but hide agent execution while composition provides only the deterministic test planner.
    let agent_service = Arc::new(AgentService::new(
        project_manager.clone(),
        state.jobs.clone(),
        state.events.clone(),
        state.identity.node_id().to_string(),
        Box::new(sparkd::agent::ScriptedBrain::plan(Vec::new())),
        Arc::new(sparkd::agent_container::PrivilegedToolRuntime::new(
            PrivilegedClient::default_socket(),
            sparkd::agent::AgentPolicy {
                allowlist_commands: sparkd::agent::DEFAULT_COMMAND_ALLOWLIST
                    .iter()
                    .map(|command| (*command).to_owned())
                    .collect(),
            },
        )),
    ));
    let state = state.with_review_only_agents(agent_service);

    // Schedule builds on Spark while paired Macs execute Xcode and return signed evidence.
    let build_service = Arc::new(BuildService::new(
        project_manager.clone(),
        state.jobs.clone(),
        state.events.clone(),
        state.identity.clone(),
        data_dir.join("work"),
    ));
    let expired_builds = build_service.requeue_expired()?;
    if expired_builds > 0 {
        tracing::info!(expired_builds, "reconciled expired Mac build claims");
    }
    let state = state
        .with_builds(build_service)
        .with_automation_runner(std::sync::Arc::new(sparkd::automations::runner::LiveRunner));

    let orphaned_terminals = state.close_orphaned_terminals()?;
    if orphaned_terminals > 0 {
        tracing::info!(
            orphaned_terminals,
            "closed terminal records left running by a previous process"
        );
    }

    let recovery = state.recover_abandoned_operations()?;
    if recovery.cancelled + recovery.failed + recovery.resumable + recovery.succeeded > 0 {
        tracing::info!(
            cancelled = recovery.cancelled,
            failed = recovery.failed,
            resumed = recovery.resumable,
            succeeded = recovery.succeeded,
            "reconciled abandoned durable operations"
        );
    }

    // Reconcile charged pool outcomes before any scheduled model can start.
    let _pool_housekeeping = sparkd::pool::spawn_housekeeping(state.clone())?;
    let _warmup_scheduler = sparkd::warmup::spawn(state.clone());
    let _automation_scheduler = sparkd::automations::scheduler::spawn(state.clone());

    if let Some(remote) = state.remote.clone() {
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(tokio::time::Duration::from_secs(30));
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                ticker.tick().await;
                let remote = remote.clone();
                let refreshed = tokio::task::spawn_blocking(move || remote.refresh_health()).await;
                if let Ok(Err(error)) = refreshed {
                    tracing::warn!(%error, "remote health refresh failed");
                }
            }
        });
    }

    let state =
        optional_services::configure(state, cli.listen, config.tls, optional_service_tls).await?;

    let app = router(state.clone());

    let advertise = config.advertise && (tls_fingerprint.is_some() || cli.advertise_insecure);
    if config.advertise && !advertise {
        tracing::warn!("not advertising over Bonjour: no TLS identity to publish");
    }
    if advertise {
        let instance = bonjour::instance_label(
            &cli.node_name,
            &bonjour::short_node_id(state.identity.node_id()),
        );
        let daemon = bonjour::advertise(
            state.identity.node_id(),
            &instance,
            tls_fingerprint.as_deref(),
            &config.runtime_version,
            cli.listen.port(),
        )?;
        tracing::info!(instance = %instance, "advertising over Bonjour");
        std::mem::forget(daemon);
    }

    // Notify readiness only after listener binding so package health checks cannot race the socket.
    let handle: axum_server::Handle<SocketAddr> = axum_server::Handle::new();
    sparkd::telemetry_history::spawn(state.clone());
    spawn_housekeeping(state.clone());
    fabric_watch::spawn_fabric_watch(state.clone());
    sparkd::project_api::development_prepare::spawn_on_boot(state.clone());
    spawn_systemd_readiness(handle.clone());
    shutdown::spawn(handle.clone(), shutdown::DRAIN_GRACE);

    let result = if config.tls {
        tracing::info!(addr = %cli.listen, "serving HTTPS");
        let identity = tls_identity.expect("TLS identity exists whenever TLS is enabled");
        let tls = axum_server::tls_rustls::RustlsConfig::from_config(identity.into_rustls_config());
        axum_server::tls_rustls::bind_rustls(cli.listen, tls)
            .handle(handle)
            .serve(sparkd::route::socket_service(app))
            .await
    } else {
        tracing::info!(addr = %cli.listen, "serving plain HTTP (development)");
        axum_server::Server::bind(cli.listen)
            .handle(handle)
            .serve(sparkd::route::socket_service(app))
            .await
    };

    let _ = spark_core::notify::stopping();
    result?;
    Ok(())
}

#[path = "startup/cli.rs"]
mod cli;
use cli::{Cli, EngineBackendChoice, default_data_dir};
#[path = "startup/cluster_monitor.rs"]
mod cluster_monitor;
#[path = "startup/fabric_watch.rs"]
mod fabric_watch;
#[path = "startup/housekeeping.rs"]
mod housekeeping;
#[path = "startup/optional_services.rs"]
mod optional_services;
use housekeeping::{spawn_housekeeping, spawn_systemd_readiness};

#[path = "startup/shutdown.rs"]
mod shutdown;
#[path = "startup/signals.rs"]
mod signals;
#[path = "startup/database.rs"]
mod startup_database;
use signals::{ReferenceSignals, primary_local_ip};
