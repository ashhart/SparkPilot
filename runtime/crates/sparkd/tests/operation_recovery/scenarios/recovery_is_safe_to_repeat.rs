/// Build a Spark whose runtime update is mid-flight, with the scripted privileged helper behind it.
fn restarting_runtime_update(
    dir: &std::path::Path,
) -> (
    AppState,
    uuid::Uuid,
    Arc<std::sync::Mutex<Vec<String>>>,
    Arc<ManualUtcClock>,
) {
    let database_path = dir.join("runtime.db");
    let now = OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let operation_id;
    {
        let mut conn = rusqlite::Connection::open(&database_path).unwrap();
        sparkd::migration::migrate_with_recovery_point(&mut conn, &database_path).unwrap();
        let actor = seed_device(&conn);
        operation_id = JobService::with_clock(clock.clone())
            .create(
                &conn,
                "system.software_updates",
                actor,
                None,
                r#"{"system_packages":false,"firmware":false,"runtime_release_id":"dev-0.2.0"}"#,
            )
            .unwrap();
        seed_running(&conn, operation_id);
        conn.execute(
            "UPDATE operations SET stage = 'runtime_update_restarting' WHERE id = ?1",
            [operation_id.to_string()],
        )
        .unwrap();
    }
    let socket = dir.join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    let backend = FakeBackend::default();
    let observed = backend.observed_operations.clone();
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, unsafe { libc::geteuid() }, &backend);
    });
    let identity = FileIdentityStore::new(dir.join("identity"))
        .load_or_create("recovery-test")
        .unwrap();
    let state = AppState::new_with_clock(
        config(dir),
        identity,
        Arc::new(FakeSystemMonitor),
        Some(rusqlite::Connection::open(&database_path).unwrap()),
        clock.clone(),
    )
    .with_privileged_socket(PrivilegedClient::new(socket));
    (state, operation_id, observed, clock)
}

fn reconciliations(observed: &Arc<std::sync::Mutex<Vec<String>>>) -> usize {
    observed
        .lock()
        .unwrap()
        .iter()
        .filter(|kind| kind.as_str() == "runtime_update_status")
        .count()
}

/// BH-27: recovery is meant to be safe to repeat; the second pass used to take the daemon down.
#[test]
fn bh_27_recovery_leaves_work_this_daemon_already_holds_alone() {
    let dir = tempfile::tempdir().unwrap();
    let (state, operation_id, observed, _clock) = restarting_runtime_update(dir.path());
    let database = state.database.clone().unwrap();
    // The worker the first pass spawned: a live lease owned by this daemon.
    let held = state.jobs.acquire_lease(database, operation_id).unwrap();

    let report = state.recover_abandoned_operations().expect("second pass");

    assert_eq!(report.resumable, 0, "the held operation was resumed again");
    assert_eq!(report.failed, 0);
    assert_eq!(
        reconciliations(&observed),
        0,
        "the side effect was repeated"
    );
    assert_eq!(operation_state(&state, operation_id).0, "running");
    held.succeed(&serde_json::json!({"done": true}))
        .expect("the worker still owns its operation");
    assert_eq!(operation_state(&state, operation_id).0, "succeeded");
}

/// BH-27: calling recovery twice in a row with one resumable operation settles it exactly once.
#[test]
fn bh_27_running_recovery_twice_settles_one_resumable_operation_once() {
    let dir = tempfile::tempdir().unwrap();
    let (state, operation_id, observed, _clock) = restarting_runtime_update(dir.path());

    let first = state.recover_abandoned_operations().expect("first pass");
    let second = state.recover_abandoned_operations().expect("second pass");

    assert_eq!(first.resumable, 1);
    assert_eq!(second.resumable, 0, "the second pass resumed it again");
    for _ in 0..200 {
        if operation_state(&state, operation_id).0 == "succeeded" {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(operation_state(&state, operation_id).0, "succeeded");
    assert_eq!(
        reconciliations(&observed),
        1,
        "the reconciliation ran more than once"
    );
}
