use super::*;
use crate::clock::ManualUtcClock;
use spark_core::identity::{FileIdentityStore, IdentityStore};
use spark_telemetry::FakeSystemMonitor;
use std::sync::Arc;

fn state() -> (tempfile::TempDir, AppState, Principal) {
    let dir = tempfile::tempdir().unwrap();
    let identity = FileIdentityStore::new(dir.path().join("identity"))
        .load_or_create("private-host-must-not-export")
        .unwrap();
    let mut db = Connection::open_in_memory().unwrap();
    crate::migration::migrate(&mut db).unwrap();
    let clock = Arc::new(ManualUtcClock::new(
        time::OffsetDateTime::from_unix_timestamp(1_800_000_000).unwrap(),
    ));
    let state = AppState::new_with_clock(
        crate::state::RuntimeConfig {
            api_major: 1,
            runtime_version: "1.0.0".into(),
            listen: "127.0.0.1:0".parse().unwrap(),
            node_name: "private-host-must-not-export".into(),
            data_dir: dir.path().to_path_buf(),
            advertise: false,
            tls: false,
        },
        identity,
        Arc::new(FakeSystemMonitor),
        Some(db),
        clock,
    );
    let principal = Principal {
        device_id: Uuid::new_v4(),
        role: "owner".into(),
        access_authentication: crate::auth::AccessAuthentication::DeviceSignature,
        user_presence: None,
    };
    state.telemetry_consent.write().functional = true;
    state.database.as_ref().unwrap().lock().execute("INSERT INTO devices (id,display_name,platform,public_key_spki,public_key_fingerprint,role,paired_at,metadata_json) VALUES (?1,'test','ios',X'010203',?2,'owner','2026-09-04T00:00:00Z','{}')",params![principal.device_id.to_string(),principal.device_id.to_string()]).unwrap();
    (dir, state, principal)
}
fn insert(conn: &Connection, id: Uuid, caller: Uuid, started: i64, outcome: &str) {
    conn.execute("INSERT INTO inference_requests(attempt_id,request_id,caller_device_id,node_id,model_id,profile_id,started_at,outcome,admission_ms,provenance_json) VALUES(?1,?2,?3,?4,'example/model','balanced',?5,?6,1.0,'{}')",params![id.to_string(),Uuid::new_v4().to_string(),caller.to_string(),Uuid::nil().to_string(),started,outcome]).unwrap();
}
fn key(caller: Uuid) -> IdempotencyRequest {
    IdempotencyRequest {
        device_id: caller,
        method: "DELETE".into(),
        path: "/api/v1/inference/requests".into(),
        key: Uuid::new_v4(),
        body_hash: crate::crypto::sha256_hex(b""),
        request_id: None,
    }
}

#[test]
fn refused_request_does_not_record_after_consent_changes_during_preparation() {
    #[derive(Debug)]
    struct WithdrawOnRead {
        consent: Arc<parking_lot::RwLock<crate::appliance_api::TelemetryConsentConfig>>,
        now: time::OffsetDateTime,
    }
    impl crate::clock::UtcClock for WithdrawOnRead {
        fn now(&self) -> time::OffsetDateTime {
            self.consent.write().functional = false;
            self.now
        }
    }
    let (_directory, state, principal) = state();
    let mut state = state.with_models(Arc::new(crate::models::ModelInventory {
        recipes: vec![spark_models::recipe::fixture::RecipeFixture::example()],
        allow_unverified_import: false,
    }));
    state.clock = Arc::new(WithdrawOnRead {
        consent: state.telemetry_consent.clone(),
        now: state.clock.now(),
    });
    record_refused(
        &state,
        &principal,
        "example/model-32b",
        "MODEL_NOT_READY",
        1.0,
    );
    assert!(!state.telemetry_consent.read().functional);
    let rows: i64 = state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row("SELECT COUNT(*) FROM inference_requests", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(
        rows, 0,
        "a prepared refusal wrote history after consent withdrawal"
    );
}

#[test]
fn restart_marks_active_attempts_unknown_without_changing_completed_records() {
    let (_dir, state, principal) = state();
    let conn = state.database.as_ref().unwrap().lock();
    let now = state.clock.now().unix_timestamp();
    insert(
        &conn,
        Uuid::new_v4(),
        principal.device_id,
        now - 1,
        "running",
    );
    insert(
        &conn,
        Uuid::new_v4(),
        principal.device_id,
        now - 2,
        "succeeded",
    );
    recover(&conn, now).unwrap();
    let rows = read(&conn, &HistoryQuery::default(), None, now).unwrap();
    assert_eq!(rows[0].outcome, "interrupted_unknown");
    assert_eq!(rows[0].failure_code.as_deref(), Some("RUNTIME_RESTARTED"));
    assert_eq!(rows[0].elapsed_ms, None);
    assert_eq!(rows[1].outcome, "succeeded");
    recover(&conn, now + 1).unwrap();
    assert_eq!(
        read(&conn, &HistoryQuery::default(), None, now + 1).unwrap()[0].finished_at,
        Some(now)
    );
}
#[test]
fn retention_is_exact_and_bounded_without_evicting_live_attempts() {
    let (_dir, state, p) = state();
    let conn = state.database.as_ref().unwrap().lock();
    let now = state.clock.now().unix_timestamp();
    let old = Uuid::new_v4();
    insert(
        &conn,
        old,
        p.device_id,
        now - RETENTION_SECONDS - 1,
        "succeeded",
    );
    let active = Uuid::new_v4();
    insert(
        &conn,
        active,
        p.device_id,
        now - RETENTION_SECONDS - 1,
        "running",
    );
    for i in 0..MAX_RECORDS + 4 {
        insert(
            &conn,
            Uuid::new_v4(),
            p.device_id,
            now - i as i64,
            "succeeded",
        );
    }
    prune(&conn, now).unwrap();
    let live: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM inference_requests WHERE attempt_id=?1",
            [active.to_string()],
            |r| r.get(0),
        )
        .unwrap();
    let gone: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM inference_requests WHERE attempt_id=?1",
            [old.to_string()],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(live, 1);
    assert_eq!(gone, 0);
    let total: i64 = conn
        .query_row("SELECT COUNT(*) FROM inference_requests", [], |r| r.get(0))
        .unwrap();
    // Active rows count toward the same cap; only terminal rows are evicted.
    assert!(total <= MAX_RECORDS as i64);
}
#[tokio::test]
async fn clear_is_caller_scoped_terminal_only_and_replay_cannot_erase_new_results() {
    let (_dir, state, p) = state();
    let now = state.clock.now().unix_timestamp();
    let other = Uuid::new_v4();
    {
        let conn = state.database.as_ref().unwrap().lock();
        insert(&conn, Uuid::new_v4(), p.device_id, now, "succeeded");
        insert(&conn, Uuid::new_v4(), p.device_id, now, "running");
        insert(&conn, Uuid::new_v4(), other, now, "succeeded");
    }
    let request = key(p.device_id);
    let (_, Json(result)) = clear(State(state.clone()), Extension(p.clone()), request.clone())
        .await
        .unwrap();
    assert_eq!(result["cleared"], 1);
    {
        let conn = state.database.as_ref().unwrap().lock();
        insert(&conn, Uuid::new_v4(), p.device_id, now, "succeeded");
    }
    let (_, Json(replay)) = clear(State(state.clone()), Extension(p.clone()), request)
        .await
        .unwrap();
    assert_eq!(result, replay);
    let conn = state.database.as_ref().unwrap().lock();
    assert_eq!(
        read(&conn, &HistoryQuery::default(), None, now)
            .unwrap()
            .len(),
        3
    );
}
#[tokio::test]
async fn history_read_filters_and_refuses_cross_caller_access() {
    let (_dir, state, mut p) = state();
    let now = state.clock.now().unix_timestamp();
    let id = Uuid::new_v4();
    {
        let conn = state.database.as_ref().unwrap().lock();
        insert(&conn, id, p.device_id, now, "succeeded");
        insert(&conn, Uuid::new_v4(), Uuid::new_v4(), now, "running");
    }
    let Json(result) = list(
        State(state.clone()),
        Extension(p.clone()),
        Query(HistoryQuery {
            attempt_id: Some(id),
            ..Default::default()
        }),
    )
    .await
    .unwrap();
    assert_eq!(result["records"].as_array().unwrap().len(), 1);
    assert_eq!(result["server_queue_ms"], Value::Null);
    let text = result.to_string();
    assert!(!text.contains("private-host-must-not-export"));
    assert!(!text.contains("127.0.0.1"));
    p.role = "user".into();
    let response = list(
        State(state.clone()),
        Extension(p),
        Query(HistoryQuery {
            all_callers: true,
            ..Default::default()
        }),
    )
    .await
    .unwrap_err();
    assert_eq!(response.0, StatusCode::FORBIDDEN);
}
#[tokio::test]
async fn cancellation_never_signals_another_callers_attempt_or_replays_after_restart() {
    let (_dir, state, p) = state();
    let now = state.clock.now().unix_timestamp();
    let own = Uuid::new_v4();
    let other = Uuid::new_v4();
    {
        let conn = state.database.as_ref().unwrap().lock();
        insert(&conn, own, p.device_id, now, "running");
        insert(&conn, other, Uuid::new_v4(), now, "running");
    }
    let (sender, receiver) = watch::channel(false);
    state.request_history.active.lock().insert(own, sender);
    assert_eq!(
        cancel(
            State(state.clone()),
            Extension(p.clone()),
            Path(other),
            key(p.device_id)
        )
        .await
        .unwrap_err()
        .0,
        StatusCode::NOT_FOUND
    );
    assert!(!*receiver.borrow());
    let _ = cancel(
        State(state.clone()),
        Extension(p.clone()),
        Path(own),
        key(p.device_id),
    )
    .await
    .unwrap();
    assert!(*receiver.borrow());
    state.request_history.active.lock().clear();
    assert_eq!(
        cancel(
            State(state.clone()),
            Extension(p.clone()),
            Path(own),
            key(p.device_id)
        )
        .await
        .unwrap_err()
        .0,
        StatusCode::CONFLICT
    );
}
#[tokio::test]
async fn withdrawn_local_consent_purges_records_instead_of_returning_them() {
    let (_dir, state, p) = state();
    {
        let conn = state.database.as_ref().unwrap().lock();
        insert(
            &conn,
            Uuid::new_v4(),
            p.device_id,
            state.clock.now().unix_timestamp(),
            "succeeded",
        );
    }
    state.telemetry_consent.write().functional = false;
    let Json(result) = list(State(state), Extension(p), Query(HistoryQuery::default()))
        .await
        .unwrap();
    assert_eq!(result["recording"], false);
    assert_eq!(result["records"], json!([]));
}
