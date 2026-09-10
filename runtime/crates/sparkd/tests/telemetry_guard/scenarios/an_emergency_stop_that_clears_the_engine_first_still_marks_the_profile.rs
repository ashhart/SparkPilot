/// The real stop worker clears the guard's active profile on its own task once the container is gone.
struct ClearsOnStop {
    guard: StdMutex<Option<std::sync::Weak<MemoryGuardService>>>,
    active: StdMutex<bool>,
}

impl ClearsOnStop {
    fn new() -> Self {
        Self {
            guard: StdMutex::new(None),
            active: StdMutex::new(true),
        }
    }

    fn attach(&self, guard: &Arc<MemoryGuardService>) {
        *self.guard.lock().unwrap() = Some(Arc::downgrade(guard));
    }
}

impl EngineControl for ClearsOnStop {
    fn drain(&self) -> Result<(), String> {
        Ok(())
    }

    fn graceful_unload(&self) -> Result<(), String> {
        Ok(())
    }

    fn emergency_stop(&self) -> Result<(), String> {
        if let Some(guard) = self.guard.lock().unwrap().as_ref().and_then(|g| g.upgrade()) {
            guard.set_active_profile(None);
        }
        *self.active.lock().unwrap() = false;
        Ok(())
    }

    fn engine_active(&self) -> bool {
        *self.active.lock().unwrap()
    }
}

#[test]
fn an_emergency_stop_that_clears_the_engine_first_still_marks_the_profile() {
    let conn = migrated_db();
    seed_profile_row(&conn);
    let database = Arc::new(Mutex::new(conn));
    let source = Arc::new(ScriptedSource::new(vec![sample(60), sample(60), sample(4)]));
    let engine = Arc::new(ClearsOnStop::new());
    let guard = Arc::new(
        MemoryGuardService::with_database(
            MemoryPolicy::default(),
            source,
            engine.clone() as Arc<dyn EngineControl>,
            EventBus::new(),
            database.clone(),
        )
        .with_technical_diagnostics(Arc::new(AtomicBool::new(true))),
    );
    engine.attach(&guard);

    guard.set_active_profile(Some(ActiveProfile {
        model_id: "llama-8b".to_owned(),
        profile_id: "balanced-16k".to_owned(),
    }));
    guard.tick(Duration::from_secs(0), "node-1");
    guard.tick(Duration::from_secs(1), "node-1");
    guard.tick(Duration::from_secs(2), "node-1");

    assert_eq!(
        guard.reading().state,
        spark_telemetry::PressureState::Emergency
    );
    let conn = database.lock();
    assert!(
        guard::profile_is_unsafe(&conn, "llama-8b", "balanced-16k").unwrap(),
        "the profile that was resident when the guard fired must be refused readmission"
    );
}
