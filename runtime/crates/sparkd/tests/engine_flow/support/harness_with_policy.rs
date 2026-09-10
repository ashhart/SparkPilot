async fn harness_with_policy(
    available_bytes: u64,
    clock: Arc<dyn UtcClock>,
    memory_recovery_timeout: Duration,
    clustered: bool,
    external_workloads: Option<ObservedWorkloads>,
) -> (Harness, SocketAddr, p256::ecdsa::SigningKey, uuid::Uuid) {
    harness_with_drain_policy(available_bytes, clock, memory_recovery_timeout, clustered,
        external_workloads, Duration::from_millis(250)).await
}

async fn harness_with_drain_policy(
    available_bytes: u64,
    clock: Arc<dyn UtcClock>,
    memory_recovery_timeout: Duration,
    clustered: bool,
    external_workloads: Option<ObservedWorkloads>,
    drain_grace: Duration,
) -> (Harness, SocketAddr, p256::ecdsa::SigningKey, uuid::Uuid) {
    harness_with_recipe_policy(available_bytes, clock, memory_recovery_timeout, clustered,
        external_workloads, drain_grace, RecipeFixture::example()).await
}

/// Install `recipe` as the fixture id so scenarios can exercise recipes that declare launch arithmetic (ADR-043).
async fn harness_with_recipe(
    available_bytes: u64,
    recipe: ModelRecipe,
) -> (Harness, SocketAddr, p256::ecdsa::SigningKey, uuid::Uuid) {
    harness_with_recipe_policy(available_bytes, system_clock(), Duration::ZERO, false, None,
        Duration::from_millis(250), recipe).await
}

async fn harness_with_recipe_policy(
    available_bytes: u64,
    clock: Arc<dyn UtcClock>,
    memory_recovery_timeout: Duration,
    clustered: bool,
    external_workloads: Option<ObservedWorkloads>,
    drain_grace: Duration,
    recipe: ModelRecipe,
) -> (Harness, SocketAddr, p256::ecdsa::SigningKey, uuid::Uuid) {
    let dir = tempfile::tempdir().expect("tempdir");
    let mut identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("engine-test")
        .expect("identity");
    identity.public.node_id = SIGNING_NODE_ID;

    let mut conn = rusqlite::Connection::open_in_memory().expect("db");
    migration::migrate(&mut conn).expect("migrate");

    let mut uninstalled = recipe.clone();
    uninstalled.metadata = spark_models::recipe::Metadata {
        id: "example/not-installed".into(),
        revision: "2026-08-25.2".into(),
        display_name: "Never installed".into(),
        publisher: "Example".into(),
        description: None,
        publisher_url: None,
        recipe_source: None,
    };
    sparkd::store::upsert_catalogue_model(&conn, &recipe).expect("upsert catalogue model");
    sparkd::store::upsert_catalogue_model(&conn, &uninstalled).expect("upsert uninstalled");
    sparkd::store::mark_model_installed(&conn, recipe.id(), 68_719_476_736)
        .expect("mark installed");

    let (monitor, available) = FixedMonitor::new(available_bytes);
    let monitor: Arc<dyn SystemMonitor> = Arc::new(monitor);
    let database = Arc::new(parking_lot::Mutex::new(conn));

    let inventory = Arc::new(sparkd::models::ModelInventory {
        recipes: vec![recipe, uninstalled],
        allow_unverified_import: false,
    });

    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".to_owned(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "engine-test".to_owned(),
        data_dir: dir.path().to_path_buf(),
        advertise: false,
        tls: false,
    };
    let mut state = AppState::new_with_clock(config, identity, monitor.clone(), None, clock)
        .with_models(inventory)
        .with_database(database.clone())
        // Disable production disk reserve here because separate tests cover disk policy and engine results must not depend on host free space.
        .with_disk_reserve(0);
    let privileged_operations = if let Some(workloads) = external_workloads {
        let backend = FakeBackend::default();
        *backend
            .observed_workloads
            .lock()
            .expect("fake workload inventory") = Some(workloads);
        let observed_operations = backend.observed_operations.clone();
        let socket = state.config.data_dir.join("spark-privd.sock");
        let listener = spark_privd::server::bind_socket(&socket).expect("privileged socket");
        let allowed_uid = unsafe { libc::geteuid() };
        std::thread::spawn(move || {
            let _ = spark_privd::server::serve(listener, allowed_uid, &backend);
        });
        state = state.with_privileged_socket(sparkd::privd::PrivilegedClient::new(socket));
        Some(observed_operations)
    } else {
        None
    };
    if clustered {
        let cluster = Arc::new(ClusterService::new(
            database.clone(),
            state.events.clone(),
            state.identity.node_id().to_string(),
            Arc::new(NoLinkProbe),
            Arc::new(NoCollectiveTest),
        ));
        cluster
            .create(
                "Test cluster",
                &[
                    MemberFacts {
                        node_id: state.identity.node_id().to_string(),
                        name: "Coordinator".into(),
                        authority_fingerprint: "test-authority".into(),
                        runtime_version: "0.1.0".into(),
                        engine_image: "test-vllm-image".into(),
                    },
                    MemberFacts {
                        node_id: uuid::Uuid::new_v4().to_string(),
                        name: "Worker".into(),
                        authority_fingerprint: "test-authority".into(),
                        runtime_version: "0.1.0".into(),
                        engine_image: "test-vllm-image".into(),
                    },
                ],
            )
            .expect("seed cluster");
        state = state.with_cluster(cluster);
    }
    let backend: Arc<MockVllmBackend> = Arc::new(MockVllmBackend::new());
    let manager = Arc::new(
        EngineManager::new(
            backend.clone(),
            state.jobs.clone(),
            state.events.clone(),
            state.identity.node_id().to_string(),
            monitor.clone(),
            database,
            dir.path().join("models"),
            drain_grace,
            None,
        )
        .with_model_policy(0, Duration::from_secs(30), memory_recovery_timeout),
    );
    let download_starts = Arc::new(AtomicU64::new(0));
    let state =
        state
            .with_engine(manager.clone())
            .with_download(sparkd::download::DownloadCoordinator {
                resolver: Box::new(EmptyResolver {
                    starts: download_starts.clone(),
                }),
                source: Box::new(UnusedSource),
            });

    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind");
    let addr = listener.local_addr().expect("addr");
    let served_state = state.clone();
    tokio::spawn(async move {
        axum::serve(listener, router(served_state))
            .await
            .expect("serve");
    });

    let device_key = fresh_device_key();
    let device_id = uuid::Uuid::new_v4();
    {
        let conn = state.database.as_ref().expect("db").lock();
        sparkd::store::insert_device(
            &conn,
            &device_id,
            "engine-test-device",
            "macos",
            &spki_der(&device_key),
            &format!("fp-engine-{device_id}"),
            "owner",
        )
        .expect("seed owner");
    }

    (
        Harness {
            state,
            available,
            backend,
            engine: manager,
            download_starts,
            privileged_operations,
            _dir: dir,
        },
        addr,
        device_key,
        device_id,
    )
}
