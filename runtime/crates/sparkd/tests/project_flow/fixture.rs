use super::*;

pub(super) struct Harness {
    pub(super) state: AppState,
    pub(super) projects: Arc<ProjectManager>,
    pub(super) containers: Arc<FakeContainerBoundary>,
    pub(super) pty: Arc<ScriptedPtyRunner>,
    pub(super) _dir: tempfile::TempDir,
}

pub(super) fn fresh_device_key() -> p256::ecdsa::SigningKey {
    loop {
        let mut scalar = [0u8; 32];
        rand::rng().fill_bytes(&mut scalar);
        if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&scalar) {
            return key;
        }
    }
}

pub(super) fn spki_der(key: &p256::ecdsa::SigningKey) -> Vec<u8> {
    key.verifying_key()
        .to_public_key_der()
        .expect("spki der")
        .as_bytes()
        .to_vec()
}

pub(super) async fn harness() -> (Harness, SocketAddr, p256::ecdsa::SigningKey, uuid::Uuid) {
    harness_with_git(Arc::new(CommandGit::new("git"))).await
}

pub(super) async fn harness_with_git(
    git: Arc<dyn spark_project_runner::GitRunner>,
) -> (Harness, SocketAddr, p256::ecdsa::SigningKey, uuid::Uuid) {
    // Darwin's per-user temporary directory leaves too little room for sockaddr_un paths.
    let dir = tempfile::Builder::new()
        .prefix("sp-")
        .tempdir_in("/tmp")
        .expect("tempdir");
    let mut identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("project-test")
        .expect("identity");
    identity.public.node_id = SIGNING_NODE_ID;

    let mut conn = rusqlite::Connection::open_in_memory().expect("db");
    migration::migrate(&mut conn).expect("migrate");
    let database = Arc::new(parking_lot::Mutex::new(conn));
    let jobs = sparkd::jobs::JobService::new();
    let events = sparkd::events::EventBus::new();

    let containers: Arc<FakeContainerBoundary> = Arc::new(FakeContainerBoundary::default());
    let pty: Arc<ScriptedPtyRunner> = Arc::new(ScriptedPtyRunner::default());
    let projects = Arc::new(ProjectManager::new(
        git,
        containers.clone(),
        pty.clone(),
        database.clone(),
        jobs.clone(),
        events.clone(),
        identity.node_id().to_string(),
        dir.path().join("projects"),
        dir.path().join("worktrees"),
    ));

    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".to_owned(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "project-test".to_owned(),
        data_dir: dir.path().to_path_buf(),
        advertise: false,
        tls: false,
    };
    let state = AppState::new(
        config,
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        None,
    )
    .with_database(database)
    .with_projects(projects.clone());

    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind");
    let addr = listener.local_addr().expect("addr");
    let served = state.clone();
    tokio::spawn(async move {
        axum::serve(listener, router(served)).await.expect("serve");
    });

    let device_key = fresh_device_key();
    let device_id = uuid::Uuid::new_v4();
    {
        let conn = state.database.as_ref().expect("db").lock();
        sparkd::store::insert_device(
            &conn,
            &device_id,
            "project-device",
            "macos",
            &spki_der(&device_key),
            &format!("fp-project-{device_id}"),
            "owner",
        )
        .expect("seed owner");
    }

    (
        Harness {
            state,
            projects,
            containers,
            pty,
            _dir: dir,
        },
        addr,
        device_key,
        device_id,
    )
}
