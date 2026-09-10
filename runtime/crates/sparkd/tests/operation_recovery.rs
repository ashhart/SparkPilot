//! Restart recovery for durable operations (§27.3).

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_models::recipe::fixture::RecipeFixture;
use spark_models::{ModelRecipe, RemoteFile};
use spark_privd::backend::FakeBackend;
use spark_telemetry::FakeSystemMonitor;
use sparkd::clock::{ManualUtcClock, UtcClock};
use sparkd::jobs::JobService;
use sparkd::privd::PrivilegedClient;
use sparkd::state::{AppState, RuntimeConfig};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

fn config(data_dir: &std::path::Path) -> RuntimeConfig {
    RuntimeConfig {
        api_major: 1,
        runtime_version: "0.1.0".into(),
        listen: "127.0.0.1:0".parse().unwrap(),
        node_name: "recovery-test".into(),
        data_dir: data_dir.into(),
        advertise: false,
        tls: false,
    }
}

fn seed_device(conn: &rusqlite::Connection) -> uuid::Uuid {
    let id = uuid::Uuid::new_v4();
    sparkd::store::insert_device(
        conn,
        &id,
        "recovery test",
        "macos",
        &[1, 2, 3],
        &format!("fingerprint-{id}"),
        "owner",
    )
    .unwrap();
    id
}

fn seed_running(conn: &rusqlite::Connection, operation_id: uuid::Uuid) {
    conn.execute(
        "UPDATE operations SET state = 'running', started_at = updated_at WHERE id = ?1",
        [operation_id.to_string()],
    )
    .unwrap();
}

fn operation_state(state: &AppState, operation_id: uuid::Uuid) -> (String, Option<String>) {
    state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT state, error_code FROM operations WHERE id = ?1",
            [operation_id.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap()
}

#[test]
fn completed_remote_enable_is_reconciled_without_repeating_the_side_effect() {
    let now = OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut conn).unwrap();
    let actor = seed_device(&conn);
    let jobs = JobService::with_clock(clock);
    let operation_id = jobs
        .create(
            &conn,
            "remote.enable",
            actor,
            None,
            r#"{"mode":"private_overlay"}"#,
        )
        .unwrap();
    seed_running(&conn, operation_id);
    conn.execute(
        "UPDATE operations SET lease_owner = 'old-daemon', lease_expires_at = '2026-08-27T12:05:00Z' WHERE id = ?1",
        [operation_id.to_string()],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO remote_access
            (singleton, enabled, mode, health, hostname, enabled_at, updated_at)
         VALUES (1, 1, 'private_overlay', 'healthy', '100.96.4.2',
                 '2026-08-27T11:59:59Z', '2026-08-27T11:59:59Z')",
        [],
    )
    .unwrap();

    let (report, actions) = jobs.recover_abandoned(&mut conn).unwrap();

    assert_eq!(report.succeeded, 1);
    assert!(actions.is_empty());
    let (state, result): (String, String) = conn
        .query_row(
            "SELECT state, result_json FROM operations WHERE id = ?1",
            [operation_id.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(state, "succeeded");
    let result: serde_json::Value = serde_json::from_str(&result).unwrap();
    assert_eq!(result["mode"], "private_overlay");
    assert_eq!(result["reconciled_after_restart"], true);
}

#[test]
fn completed_remote_disable_is_reconciled_without_stopping_anything_twice() {
    let now = OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut conn).unwrap();
    let actor = seed_device(&conn);
    let jobs = JobService::with_clock(clock);
    let operation_id = jobs
        .create(&conn, "remote.disable", actor, None, "{}")
        .unwrap();
    seed_running(&conn, operation_id);
    conn.execute(
        "UPDATE operations SET lease_owner = 'old-daemon', lease_expires_at = '2026-08-27T12:05:00Z' WHERE id = ?1",
        [operation_id.to_string()],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO remote_access
            (singleton, enabled, mode, health, enabled_at, updated_at)
         VALUES (1, 0, 'disabled', 'disabled',
                 '2026-08-27T11:59:59Z', '2026-08-27T11:59:59Z')",
        [],
    )
    .unwrap();

    let (report, actions) = jobs.recover_abandoned(&mut conn).unwrap();

    assert_eq!(report.succeeded, 1);
    assert!(actions.is_empty());
    let state: String = conn
        .query_row(
            "SELECT state FROM operations WHERE id = ?1",
            [operation_id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(state, "succeeded");
}

#[test]
fn remote_recovery_does_not_claim_success_when_durable_state_did_not_change() {
    let now = OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut conn).unwrap();
    let actor = seed_device(&conn);
    let jobs = JobService::with_clock(clock);
    let operation_id = jobs
        .create(
            &conn,
            "remote.enable",
            actor,
            None,
            r#"{"mode":"private_overlay"}"#,
        )
        .unwrap();
    seed_running(&conn, operation_id);
    conn.execute(
        "UPDATE operations SET lease_owner = 'old-daemon', lease_expires_at = '2026-08-27T12:05:00Z' WHERE id = ?1",
        [operation_id.to_string()],
    )
    .unwrap();

    let (report, actions) = jobs.recover_abandoned(&mut conn).unwrap();

    assert_eq!(report, sparkd::jobs::RecoveryReport::default());
    assert!(actions.is_empty());
    let state: String = conn
        .query_row(
            "SELECT state FROM operations WHERE id = ?1",
            [operation_id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(state, "running");
}

struct EmptyResolver {
    calls: Arc<AtomicUsize>,
}

impl sparkd::download::SourceResolver for EmptyResolver {
    fn resolve(&self, _recipe: &ModelRecipe) -> Result<Vec<RemoteFile>, String> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(Vec::new())
    }
}

struct UnusedSource;

impl sparkd::download::FileSource for UnusedSource {
    fn fetch(
        &self,
        _recipe: &ModelRecipe,
        _file: &RemoteFile,
        _range: Option<(u64, usize)>,
    ) -> Result<Vec<u8>, String> {
        panic!("empty manifests never fetch")
    }
}

#[test]
fn expired_running_operation_is_not_left_running_after_restart() {
    let dir = tempfile::tempdir().unwrap();
    let database_path = dir.path().join("runtime.db");
    let now = OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let operation_id;
    {
        let mut conn = rusqlite::Connection::open(&database_path).unwrap();
        sparkd::migration::migrate_with_recovery_point(&mut conn, &database_path).unwrap();
        let actor = seed_device(&conn);
        let jobs = JobService::with_clock(clock.clone());
        operation_id = jobs
            .create(
                &conn,
                "model.load",
                actor,
                Some("example/model-32b"),
                r#"{"model":"example/model-32b","profile":"balanced-16k"}"#,
            )
            .unwrap();
        seed_running(&conn, operation_id);
        conn.execute(
            "UPDATE operations
                SET lease_owner = 'dead-daemon', lease_expires_at = '2026-08-27T11:59:00Z'
              WHERE id = ?1",
            [operation_id.to_string()],
        )
        .unwrap();
    }

    let identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("recovery-test")
        .unwrap();
    let reopened = rusqlite::Connection::open(&database_path).unwrap();
    let restarted = AppState::new_with_clock(
        config(dir.path()),
        identity,
        Arc::new(FakeSystemMonitor),
        Some(reopened),
        clock as Arc<dyn UtcClock>,
    );
    restarted.recover_abandoned_operations().unwrap();
    let (state, error_code) = operation_state(&restarted, operation_id);
    assert_eq!(state, "failed");
    assert_eq!(
        error_code.as_deref(),
        Some("OPERATION_ENGINE_STATE_RECONCILIATION_REQUIRED")
    );
}

#[test]
fn cancelling_operation_becomes_cancelled_after_restart() {
    let dir = tempfile::tempdir().unwrap();
    let now = OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut conn).unwrap();
    let actor = seed_device(&conn);
    let jobs = JobService::with_clock(clock.clone());
    let operation_id = jobs
        .create(
            &conn,
            "model.install",
            actor,
            Some("example/model-32b"),
            "{}",
        )
        .unwrap();
    jobs.persist_cancellation_request(&conn, operation_id)
        .unwrap();
    let identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("recovery-test")
        .unwrap();
    let state = AppState::new_with_clock(
        config(dir.path()),
        identity,
        Arc::new(FakeSystemMonitor),
        Some(conn),
        clock,
    );

    state.recover_abandoned_operations().unwrap();

    assert_eq!(
        operation_state(&state, operation_id),
        (
            "cancelled".to_owned(),
            Some("OPERATION_CANCELLED_DURING_RESTART".to_owned())
        )
    );
}

#[test]
fn a_live_foreign_lease_is_not_stolen() {
    let dir = tempfile::tempdir().unwrap();
    let now = OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut conn).unwrap();
    let actor = seed_device(&conn);
    let jobs = JobService::with_clock(clock.clone());
    let operation_id = jobs
        .create(&conn, "project.create", actor, None, "{}")
        .unwrap();
    seed_running(&conn, operation_id);
    conn.execute(
        "UPDATE operations SET lease_owner = 'other', lease_expires_at = '2026-08-27T12:05:00Z' WHERE id = ?1",
        [operation_id.to_string()],
    )
    .unwrap();
    let identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("recovery-test")
        .unwrap();
    let state = AppState::new_with_clock(
        config(dir.path()),
        identity,
        Arc::new(FakeSystemMonitor),
        Some(conn),
        clock,
    );

    let report = state.recover_abandoned_operations().unwrap();

    assert_eq!(report, sparkd::jobs::RecoveryReport::default());
    assert_eq!(
        operation_state(&state, operation_id),
        ("running".to_owned(), None)
    );
}

#[test]
fn catalogue_refresh_is_resumed_with_its_verified_candidate_after_restart() {
    let now = OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut conn).unwrap();
    let actor = seed_device(&conn);
    let jobs = JobService::with_clock(clock);
    let candidate_json = r#"{"recipes":[],"signature":{"key_id":"catalogue-test","algorithm":"ed25519","value":"candidate"}}"#;
    let operation_id = jobs
        .create(
            &conn,
            "catalogue.refresh",
            actor,
            Some("catalogue"),
            &serde_json::json!({ "candidate_json": candidate_json }).to_string(),
        )
        .unwrap();
    seed_running(&conn, operation_id);
    conn.execute(
        "UPDATE operations SET lease_owner = 'old-daemon', lease_expires_at = '2026-08-27T12:05:00Z' WHERE id = ?1",
        [operation_id.to_string()],
    )
    .unwrap();

    let (report, actions) = jobs.recover_abandoned(&mut conn).unwrap();
    assert_eq!(report.resumable, 1);
    assert_eq!(actions.len(), 1);
    assert!(matches!(
        &actions[0],
        sparkd::jobs::RecoveryAction::ResumeCatalogueRefresh {
            operation_id: recovered,
            candidate_json: recovered_json,
        } if *recovered == operation_id && recovered_json == candidate_json
    ));
    let state: String = conn
        .query_row(
            "SELECT state FROM operations WHERE id = ?1",
            [operation_id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(state, "queued");
}

#[test]
fn runtime_update_reconciles_after_daemon_restart_even_with_the_old_live_lease() {
    let dir = tempfile::tempdir().unwrap();
    let database_path = dir.path().join("runtime.db");
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
            "UPDATE operations
                SET stage = 'runtime_update_restarting', lease_owner = 'old-daemon',
                    lease_expires_at = '2026-08-27T12:05:00Z'
              WHERE id = ?1",
            [operation_id.to_string()],
        )
        .unwrap();
    }

    let socket = dir.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket).unwrap();
    let backend = FakeBackend::default();
    let observed = backend.observed_operations.clone();
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, unsafe { libc::geteuid() }, &backend);
    });
    let identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("recovery-test")
        .unwrap();
    let state = AppState::new_with_clock(
        config(dir.path()),
        identity,
        Arc::new(FakeSystemMonitor),
        Some(rusqlite::Connection::open(&database_path).unwrap()),
        clock,
    )
    .with_privileged_socket(PrivilegedClient::new(socket));

    let report = state.recover_abandoned_operations().unwrap();
    for _ in 0..100 {
        if operation_state(&state, operation_id).0 == "succeeded" {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    assert_eq!(report.resumable, 1);
    assert_eq!(operation_state(&state, operation_id).0, "succeeded");
    assert_eq!(
        observed
            .lock()
            .unwrap()
            .iter()
            .filter(|kind| kind.as_str() == "runtime_update_status")
            .count(),
        1
    );
}

#[test]
fn interrupted_unsafe_kind_fails_retryably_instead_of_repeating() {
    let dir = tempfile::tempdir().unwrap();
    let now = OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut conn).unwrap();
    let actor = seed_device(&conn);
    let jobs = JobService::with_clock(clock.clone());
    let operation_id = jobs
        .create(
            &conn,
            "remote.enable",
            actor,
            None,
            r#"{"token":"not-persisted"}"#,
        )
        .unwrap();
    seed_running(&conn, operation_id);
    let identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("recovery-test")
        .unwrap();
    let state = AppState::new_with_clock(
        config(dir.path()),
        identity,
        Arc::new(FakeSystemMonitor),
        Some(conn),
        clock,
    );

    state.recover_abandoned_operations().unwrap();

    assert_eq!(
        operation_state(&state, operation_id),
        (
            "failed".to_owned(),
            Some("OPERATION_INTERRUPTED_RETRYABLE".to_owned())
        )
    );
}

#[test]
fn content_addressed_install_resumes_once_after_database_restart() {
    let dir = tempfile::tempdir().unwrap();
    let database_path = dir.path().join("runtime.db");
    let now = OffsetDateTime::parse("2026-08-27T12:00:00Z", &Rfc3339).unwrap();
    let clock = Arc::new(ManualUtcClock::new(now));
    let mut recipe = RecipeFixture::example();
    // Use the valid minimum memory reserve while testing recovery, with disk policy controlled independently.
    recipe.memory.minimum_system_reserve_bytes = 8 * 1024 * 1024 * 1024;
    let operation_id;
    {
        let mut conn = rusqlite::Connection::open(&database_path).unwrap();
        sparkd::migration::migrate_with_recovery_point(&mut conn, &database_path).unwrap();
        sparkd::store::upsert_catalogue_model(&conn, &recipe).unwrap();
        let actor = seed_device(&conn);
        let jobs = JobService::with_clock(clock.clone());
        operation_id = jobs
            .create(
                &conn,
                "model.install",
                actor,
                Some(recipe.id()),
                &serde_json::json!({"model": recipe.id()}).to_string(),
            )
            .unwrap();
        seed_running(&conn, operation_id);
    }
    let calls = Arc::new(AtomicUsize::new(0));
    let identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("recovery-test")
        .unwrap();
    let state = AppState::new_with_clock(
        config(dir.path()),
        identity,
        Arc::new(FakeSystemMonitor),
        Some(rusqlite::Connection::open(&database_path).unwrap()),
        clock,
    )
    .with_models(Arc::new(sparkd::models::ModelInventory {
        recipes: vec![recipe],
        allow_unverified_import: false,
    }))
    .with_download(sparkd::download::DownloadCoordinator {
        resolver: Box::new(EmptyResolver {
            calls: calls.clone(),
        }),
        source: Box::new(UnusedSource),
    })
    // Remove production reserve because recovery reads real filesystem capacity and should not depend on developer disk pressure.
    .with_disk_reserve(0);

    state.recover_abandoned_operations().unwrap();
    for _ in 0..100 {
        if operation_state(&state, operation_id).0 == "succeeded" {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    state.recover_abandoned_operations().unwrap();

    assert_eq!(operation_state(&state, operation_id).0, "succeeded");
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

include!("operation_recovery/scenarios/recovery_is_safe_to_repeat.rs");
