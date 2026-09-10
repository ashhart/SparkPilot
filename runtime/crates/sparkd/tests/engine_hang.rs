//! Fail and clean up an engine that never becomes healthy within the configured model health window.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use spark_models::recipe::fixture::RecipeFixture;
use spark_telemetry::{InferenceSnapshot, MemoryPressure, SystemMonitor, SystemSnapshot};
use sparkd::engine::{BackendError, EngineBackend, EngineImagePreparation, EngineInstance};

/// Provide ample memory so only the intended health timeout can refuse the load.
struct RoomyMonitor;

impl SystemMonitor for RoomyMonitor {
    fn system(&self) -> SystemSnapshot {
        SystemSnapshot {
            unified_memory_total_bytes: 240 << 30,
            unified_memory_available_bytes: 200 << 30,
            memory_pressure: MemoryPressure::Normal,
            cpu_utilisation: 0.10,
            load_average_1m: 0.5,
            disk_free_bytes: 100 << 30,
            temperature_celsius: Some(40.0),
            power_state: "normal".into(),
            uptime_seconds: 1_000,
        }
    }

    fn inference(&self) -> InferenceSnapshot {
        InferenceSnapshot::default()
    }
}

/// Keep the launched engine running but permanently unhealthy to model a hung vLLM process.
struct HangingBackend {
    health_polls: Arc<AtomicUsize>,
    stops: Arc<AtomicUsize>,
}

#[async_trait::async_trait]
impl EngineBackend for HangingBackend {
    async fn prepare(
        &self,
        _instance: &EngineInstance,
    ) -> Result<EngineImagePreparation, BackendError> {
        Ok(EngineImagePreparation::AlreadyAvailable)
    }

    async fn launch(&self, instance: &EngineInstance) -> Result<u16, BackendError> {
        Ok(instance.internal_port)
    }

    async fn stop(&self, _instance: &EngineInstance, _force: bool) -> Result<(), BackendError> {
        self.stops.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    async fn reconcile_instance(
        &self,
        _instance_id: uuid::Uuid,
        _external_workload_id: Option<&str>,
    ) -> Result<(), BackendError> {
        Ok(())
    }

    async fn is_running(&self, _instance: &EngineInstance) -> bool {
        true
    }

    async fn health(&self, _instance: &EngineInstance) -> Result<bool, BackendError> {
        self.health_polls.fetch_add(1, Ordering::SeqCst);
        Ok(false)
    }

    async fn list_model_names(
        &self,
        _instance: &EngineInstance,
    ) -> Result<Vec<String>, BackendError> {
        Err(BackendError("engine never became ready".into()))
    }

    async fn probe_completion(&self, _instance: &EngineInstance) -> Result<(), BackendError> {
        Err(BackendError("engine never became ready".into()))
    }

    fn probe_container_runtime(&self) -> sparkd::engine::ContainerRuntimeReport {
        sparkd::engine::ContainerRuntimeReport::new("mock", true, None)
    }
}

#[tokio::test]
async fn a_hung_engine_fails_the_load_inside_the_configured_window() {
    let directory = tempfile::tempdir().unwrap();
    let health_polls = Arc::new(AtomicUsize::new(0));
    let stops = Arc::new(AtomicUsize::new(0));
    let backend = Arc::new(HangingBackend {
        health_polls: health_polls.clone(),
        stops: stops.clone(),
    });

    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut connection).unwrap();
    let recipe = RecipeFixture::example();
    sparkd::store::upsert_catalogue_model(&connection, &recipe).unwrap();
    sparkd::store::mark_model_installed(&connection, recipe.id(), 68_719_476_736).unwrap();
    let actor = uuid::Uuid::new_v4();
    sparkd::store::insert_device(
        &connection,
        &actor,
        "hang test",
        "macos",
        &[1, 2, 3],
        &format!("hang-{actor}"),
        "owner",
    )
    .unwrap();
    let jobs = sparkd::jobs::JobService::new();
    let operation_id = jobs
        .create(&connection, "model.load", actor, Some(recipe.id()), "{}")
        .unwrap();
    let database = Arc::new(parking_lot::Mutex::new(connection));
    let events = sparkd::events::EventBus::new();
    let monitor: Arc<dyn SystemMonitor> = Arc::new(RoomyMonitor);

    // Create a mountable snapshot fixture; the unhealthy backend never reads its content.
    let snapshot = directory
        .path()
        .join("models/snapshots")
        .join(recipe.id().replace('/', "_"));
    std::fs::create_dir_all(&snapshot).unwrap();

    let manager = Arc::new(
        sparkd::engine::EngineManager::new(
            backend.clone(),
            jobs.clone(),
            events,
            uuid::Uuid::new_v4().to_string(),
            monitor,
            database.clone(),
            directory.path().join("models"),
            Duration::from_millis(100),
            None,
        )
        // Exercise the real configured one-second health deadline without bypassing the polling path.
        .with_model_policy(0, Duration::from_secs(1), Duration::from_secs(5)),
    );

    let started = std::time::Instant::now();
    manager
        .spawn_load(operation_id, &recipe, &recipe.profiles[0].id, false)
        .expect("the load is queued");

    // Require terminal failure specifically from the health timeout rather than another test deadline.
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    let (state, error_code) = loop {
        let row: (String, Option<String>) = database
            .lock()
            .query_row(
                "SELECT state, error_code FROM operations WHERE id = ?1",
                [operation_id.to_string()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        if row.0 == "failed" || row.0 == "succeeded" {
            break row;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the load never reached a terminal state; a hung engine must not \
             hold an operation open indefinitely"
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    };
    let elapsed = started.elapsed();

    assert_eq!(state, "failed", "a hung engine must not report success");
    let error_code = error_code.unwrap_or_default();
    assert!(
        error_code.contains("health check timed out"),
        "the failure must name the health timeout, not an unrelated error: {error_code}"
    );
    assert!(
        health_polls.load(Ordering::SeqCst) > 0,
        "the health endpoint must actually be polled"
    );
    assert!(
        stops.load(Ordering::SeqCst) > 0,
        "a failed load must stop the container it started, or the next load \
         collides with an orphan"
    );
    assert!(
        elapsed >= Duration::from_millis(800),
        "the wait must last the configured window ({elapsed:?})"
    );
    assert!(
        elapsed < Duration::from_secs(15),
        "the wait must be bounded by the configured window ({elapsed:?})"
    );
}
