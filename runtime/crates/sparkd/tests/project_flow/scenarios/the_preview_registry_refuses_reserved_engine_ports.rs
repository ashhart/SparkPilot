/// Reject runtime-owned ports at registration independently of upstream devcontainer parsing, and drop ports with their container.
#[test]
fn the_preview_registry_refuses_reserved_engine_ports() {
    let dir = tempfile::tempdir().expect("tempdir");
    let mut conn = rusqlite::Connection::open_in_memory().expect("db");
    migration::migrate(&mut conn).expect("migrate");
    let projects = ProjectManager::new(
        Arc::new(CommandGit::new("git")),
        Arc::new(FakeContainerBoundary::default()),
        Arc::new(ScriptedPtyRunner::default()),
        Arc::new(parking_lot::Mutex::new(conn)),
        sparkd::jobs::JobService::new(),
        sparkd::events::EventBus::new(),
        uuid::Uuid::new_v4().to_string(),
        dir.path().join("projects"),
        dir.path().join("worktrees"),
    );
    let project_id = uuid::Uuid::new_v4();

    for port in [
        sparkd::engine::INTERNAL_PORT_RANGE_START,
        18150,
        sparkd::engine::INTERNAL_PORT_RANGE_END,
    ]
    .into_iter()
    .chain(spark_core::RUNTIME_SERVICE_PORTS)
    {
        projects.register_preview_port(&project_id, port, "spark-project-a");
        assert!(
            !projects.preview_port_registered(&project_id, port),
            "runtime-owned port {port} must never become previewable"
        );
    }

    // An ordinary application port is unaffected, and it leaves with its container.
    projects.register_preview_port(&project_id, 5173, "spark-project-a");
    assert!(projects.preview_port_registered(&project_id, 5173));
    projects.unregister_preview_container(&project_id, "spark-project-a");
    assert!(!projects.preview_port_registered(&project_id, 5173));
}
