use super::*;
use crate::automations::store::Automation;
use crate::clock::ManualUtcClock;
use crate::state::{AppState, RuntimeConfig};
use spark_core::identity::{FileIdentityStore, IdentityStore};

include!("tests/admission.rs");

/// Answers with a fixed result and counts how many times it was asked to run.
#[derive(Debug, Default)]
struct CountingRunner {
    runs: Arc<Mutex<Vec<Uuid>>>,
}

#[async_trait::async_trait]
impl AutomationRunner for CountingRunner {
    async fn run(&self, _state: &AppState, automation: &Automation) -> RunOutcome {
        self.runs.lock().push(automation.id);
        RunOutcome {
            text: "Overnight, nothing exploded.".to_owned(),
            error_code: None,
            tool_calls: vec![json!({"index": 0, "tool": "web_search", "outcome": "succeeded"})],
        }
    }
}

/// Records whether the run's operation carried a live lease while the model was working.
#[derive(Debug)]
struct LeaseObservingRunner {
    leased: Arc<Mutex<Option<bool>>>,
}

#[async_trait::async_trait]
impl AutomationRunner for LeaseObservingRunner {
    async fn run(&self, state: &AppState, _automation: &Automation) -> RunOutcome {
        let held = state.database.as_ref().is_some_and(|database| {
            database
                .lock()
                .query_row(
                    "SELECT COUNT(*) FROM operations
                       WHERE kind = ?1 AND lease_owner IS NOT NULL AND state = 'running'",
                    [RUN_KIND],
                    |row| row.get::<_, i64>(0),
                )
                .is_ok_and(|count| count == 1)
        });
        *self.leased.lock() = Some(held);
        RunOutcome::default()
    }
}

/// Panics for the first `panics` runs, then answers normally.
#[derive(Debug)]
struct PanickingRunner {
    left: Arc<Mutex<usize>>,
    runs: Arc<Mutex<Vec<Uuid>>>,
}

#[async_trait::async_trait]
impl AutomationRunner for PanickingRunner {
    async fn run(&self, _state: &AppState, automation: &Automation) -> RunOutcome {
        let mut left = self.left.lock();
        if *left > 0 {
            *left -= 1;
            drop(left);
            panic!("the model loop fell over");
        }
        drop(left);
        self.runs.lock().push(automation.id);
        RunOutcome {
            text: "Recovered.".to_owned(),
            error_code: None,
            tool_calls: Vec::new(),
        }
    }
}

struct Harness {
    state: AppState,
    clock: Arc<ManualUtcClock>,
    runs: Arc<Mutex<Vec<Uuid>>>,
    _directory: tempfile::TempDir,
}

fn harness(now: i64) -> Harness {
    let directory = tempfile::tempdir().expect("directory");
    let identity = FileIdentityStore::new(directory.path().join("identity"))
        .load_or_create("automation-test")
        .expect("identity");
    let mut connection = rusqlite::Connection::open_in_memory().expect("memory database");
    crate::migration::migrate(&mut connection).expect("migrations");
    let clock = Arc::new(ManualUtcClock::new(
        time::OffsetDateTime::from_unix_timestamp(now).expect("in range"),
    ));
    let config = RuntimeConfig {
        api_major: 1,
        runtime_version: "test".into(),
        listen: "127.0.0.1:0".parse().expect("address"),
        node_name: "automation-test".into(),
        data_dir: directory.path().to_path_buf(),
        advertise: false,
        tls: false,
    };
    let mut state = AppState::new_with_clock(
        config,
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        Some(connection),
        clock.clone(),
    );
    let runs = Arc::new(Mutex::new(Vec::new()));
    state.automations =
        AutomationService::with_runner(Arc::new(CountingRunner { runs: runs.clone() }));
    Harness {
        state,
        clock,
        runs,
        _directory: directory,
    }
}

impl Harness {
    fn seed(&self, next_run_at: Option<i64>) -> Automation {
        let database = self.state.database.as_ref().expect("database");
        let conn = database.lock();
        let owner = Uuid::new_v4();
        crate::store::insert_device(
            &conn,
            &owner,
            "phone",
            "ios",
            b"spki",
            &format!("fp-{owner}"),
            "owner",
        )
        .expect("device");
        let draft = Automation {
            id: Uuid::new_v4(),
            owner_device_id: owner,
            name: "Daily brief".to_owned(),
            instructions: "Tell me what happened overnight.".to_owned(),
            schedule_preset: "daily".to_owned(),
            schedule_expression: "0 7 * * *".to_owned(),
            timezone: "Europe/London".to_owned(),
            model_id: "a-model".to_owned(),
            profile_id: None,
            web_access: false,
            notify: true,
            enabled: true,
            next_run_at: None,
            created_at: 0,
            updated_at: 0,
        };
        store::insert(
            &conn,
            self.state.identity.node_id(),
            owner,
            &draft,
            next_run_at,
            0,
        )
        .expect("insert")
    }

    fn runs_of(&self, automation: Uuid) -> Vec<crate::automations::store::AutomationRun> {
        let database = self.state.database.as_ref().expect("database");
        let conn = database.lock();
        store::runs(&conn, automation).expect("runs")
    }

    fn operation_state(&self, run_id: Uuid) -> (String, Option<String>) {
        let database = self.state.database.as_ref().expect("database");
        let conn = database.lock();
        let operation = store::run(&conn, run_id)
            .expect("run")
            .expect("row")
            .operation_id
            .expect("operation");
        conn.query_row(
            "SELECT state, error_code FROM operations WHERE id = ?1",
            [operation.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("operation row")
    }

    fn reload(&self, automation: Uuid) -> Automation {
        let database = self.state.database.as_ref().expect("database");
        let conn = database.lock();
        store::get(&conn, automation).expect("get").expect("row")
    }
}

#[tokio::test]
async fn a_due_automation_fires_once_and_its_next_slot_moves_forward() {
    let harness = harness(1_767_596_400);
    let automation = harness.seed(Some(1_767_596_400));
    run_due(&harness.state).await.expect("pass");
    let runs = harness.runs_of(automation.id);
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].state, "succeeded");
    assert_eq!(runs[0].trigger, "schedule");
    assert_eq!(runs[0].scheduled_for, Some(1_767_596_400));
    assert_eq!(
        runs[0].result_text.as_deref(),
        Some("Overnight, nothing exploded.")
    );
    assert_eq!(runs[0].tool_calls.len(), 1);
    assert!(runs[0].operation_id.is_some(), "no durable operation");
    let reloaded = harness.reload(automation.id);
    assert_eq!(reloaded.next_run_at, Some(1_767_596_400 + 86_400));
}

#[tokio::test]
async fn a_second_pass_in_the_same_second_does_not_fire_again() {
    let harness = harness(1_767_596_400);
    let automation = harness.seed(Some(1_767_596_400));
    run_due(&harness.state).await.expect("first pass");
    run_due(&harness.state).await.expect("second pass");
    run_due(&harness.state).await.expect("third pass");
    assert_eq!(harness.runs.lock().len(), 1);
    assert_eq!(harness.runs_of(automation.id).len(), 1);
}

#[tokio::test]
async fn a_restart_in_the_middle_of_a_slot_leaves_exactly_one_run() {
    let harness = harness(1_767_596_400);
    let automation = harness.seed(Some(1_767_596_400));
    let database = harness.state.database.clone().expect("database");
    // Claim the slot the way the scheduler does, then stop as a restart would.
    let claimed = {
        let conn = database.lock();
        store::claim_run(
            &conn,
            automation.id,
            "schedule",
            Some(1_767_596_400),
            1_767_596_400,
        )
        .expect("claim")
        .expect("id")
    };
    {
        let conn = database.lock();
        conn.execute(
            "UPDATE automations SET next_run_at=?2 WHERE id=?1",
            rusqlite::params![automation.id.to_string(), 1_767_596_400 + 86_400],
        )
        .expect("advance");
    }
    reconcile(&database.lock(), 1_767_596_500, true).expect("restart recovery");
    let after_restart = harness.runs_of(automation.id);
    assert_eq!(after_restart.len(), 1);
    assert_eq!(after_restart[0].id, claimed);
    assert_eq!(after_restart[0].state, "interrupted");
    assert_eq!(
        after_restart[0].error_code.as_deref(),
        Some("AUTOMATION_RUN_INTERRUPTED")
    );

    harness
        .clock
        .set(time::OffsetDateTime::from_unix_timestamp(1_767_596_500).expect("in range"));
    run_due(&harness.state).await.expect("pass after restart");
    let runs = harness.runs_of(automation.id);
    assert_eq!(runs.len(), 1, "the interrupted slot was replayed");
    assert!(harness.runs.lock().is_empty(), "the model was asked twice");
}

#[tokio::test]
async fn a_spark_that_was_off_for_days_records_the_missed_slot_and_does_not_catch_up() {
    let harness = harness(1_767_596_400 + 3 * 86_400);
    let automation = harness.seed(Some(1_767_596_400));
    run_due(&harness.state).await.expect("pass");
    let runs = harness.runs_of(automation.id);
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].state, "skipped");
    assert_eq!(
        runs[0].error_code.as_deref(),
        Some("AUTOMATION_SLOT_MISSED")
    );
    assert!(
        harness.runs.lock().is_empty(),
        "a missed slot was still run"
    );
    assert!(
        harness
            .reload(automation.id)
            .next_run_at
            .is_some_and(|slot| slot > 1_767_596_400),
        "the schedule did not move past the missed slot"
    );
}

#[tokio::test]
async fn a_disabled_automation_is_left_alone() {
    let harness = harness(1_767_596_400);
    let automation = harness.seed(Some(1_767_596_400));
    {
        let database = harness.state.database.as_ref().expect("database");
        let conn = database.lock();
        let mut disabled = store::get(&conn, automation.id).expect("get").expect("row");
        disabled.enabled = false;
        store::update(&conn, &disabled, 0).expect("disable");
    }
    run_due(&harness.state).await.expect("pass");
    assert!(harness.runs_of(automation.id).is_empty());
    assert!(harness.runs.lock().is_empty());
}

/// BH-24: a manual run holds the only in-flight slot, so the scheduler records the collision.
#[tokio::test]
async fn bh_24_a_manual_run_in_flight_makes_the_scheduler_skip_the_slot() {
    let harness = harness(1_767_596_400);
    let automation = harness.seed(Some(1_767_596_400));
    let database = harness.state.database.clone().expect("database");
    let manual = {
        let conn = database.lock();
        store::claim_run(&conn, automation.id, "manual", None, 1_767_596_300)
            .expect("manual claim")
            .expect("id")
    };

    run_due(&harness.state).await.expect("pass");

    assert!(
        harness.runs.lock().is_empty(),
        "the scheduler ran a second copy of an automation that was already running"
    );
    let runs = harness.runs_of(automation.id);
    let skipped = runs
        .iter()
        .find(|run| run.id != manual)
        .expect("the collision was recorded");
    assert_eq!(skipped.state, "skipped");
    assert_eq!(
        skipped.error_code.as_deref(),
        Some("AUTOMATION_RUN_IN_FLIGHT")
    );
    assert_eq!(
        harness.reload(automation.id).next_run_at,
        Some(1_767_596_400 + 86_400),
        "the slot still moved on"
    );
}

/// BH-26: a forward clock jump used to walk the backlog one slot per second.
#[tokio::test]
async fn bh_26_a_week_of_missed_slots_is_settled_in_one_pass() {
    let start = 1_767_596_400;
    let week = 7 * 86_400;
    let harness = harness(start + week);
    let automation = harness.seed(Some(start));

    run_due(&harness.state).await.expect("one pass");

    assert!(
        harness.runs.lock().is_empty(),
        "a missed slot was run after the fact"
    );
    let runs = harness.runs_of(automation.id);
    assert_eq!(runs.len(), 1, "one aggregate record, not one per slot");
    assert_eq!(runs[0].state, "skipped");
    assert_eq!(
        runs[0].error_code.as_deref(),
        Some("AUTOMATION_SLOT_MISSED")
    );
    let next = harness
        .reload(automation.id)
        .next_run_at
        .expect("the schedule resumed");
    assert!(
        next > start + week,
        "the backlog was not skipped: next slot {next} is not after now"
    );
    assert!(
        next <= start + week + 86_400,
        "the schedule resumed further out than the next real slot"
    );

    let database = harness.state.database.clone().expect("database");
    let (event_count, missed): (i64, i64) = database
        .lock()
        .query_row(
            "SELECT COUNT(*), COALESCE(MAX(json_extract(payload_json, '$.missed')), 0)
               FROM events WHERE event_type = 'automation.slots.missed'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("event");
    assert_eq!(event_count, 1, "one aggregate event for the whole backlog");
    assert_eq!(
        missed, 8,
        "seven daily slots plus the one due at this instant were missed"
    );
}

/// A minute-by-minute schedule over a week settles in the same single pass.
#[tokio::test]
async fn bh_26_a_dense_backlog_does_not_walk_slot_by_slot() {
    let start = 1_767_596_400;
    let week = 7 * 86_400;
    let harness = harness(start + week);
    let automation = harness.seed(Some(start));
    {
        let database = harness.state.database.as_ref().expect("database");
        let conn = database.lock();
        let mut dense = store::get(&conn, automation.id).expect("get").expect("row");
        dense.schedule_expression = "* * * * *".to_owned();
        dense.schedule_preset = "custom".to_owned();
        store::update(&conn, &dense, 0).expect("dense schedule");
    }

    let began = std::time::Instant::now();
    run_due(&harness.state).await.expect("one pass");
    // A slot-by-slot walk of this backlog would take hours; the bound only has to be far below that on a loaded machine.
    assert!(
        began.elapsed() < std::time::Duration::from_secs(60),
        "one pass took {:?}",
        began.elapsed()
    );

    assert_eq!(harness.runs_of(automation.id).len(), 1);
    let next = harness
        .reload(automation.id)
        .next_run_at
        .expect("the schedule resumed");
    assert!(next > start + week && next <= start + week + 60);
}

/// BH-37: an early return used to leave the operation queued for ever.
#[tokio::test]
async fn bh_37_a_run_without_a_runner_settles_its_operation_too() {
    let mut harness = harness(1_767_596_400);
    harness.state.automations = AutomationService::default();
    let automation = harness.seed(Some(1_767_596_400));

    run_due(&harness.state).await.expect("pass");

    let runs = harness.runs_of(automation.id);
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].state, "failed");
    assert_eq!(
        runs[0].error_code.as_deref(),
        Some("AUTOMATION_RUNNER_UNAVAILABLE")
    );
    let (state, code) = harness.operation_state(runs[0].id);
    assert_eq!(state, "failed", "the operation was left queued");
    assert_eq!(code.as_deref(), Some("AUTOMATION_RUNNER_UNAVAILABLE"));
}

/// BH-37: a run holds a lease while it works, so nothing can be left running with no owner.
#[tokio::test]
async fn bh_37_a_completed_run_settles_its_operation_through_a_lease() {
    let mut harness = harness(1_767_596_400);
    let leased = Arc::new(Mutex::new(None));
    harness.state.automations = AutomationService::with_runner(Arc::new(LeaseObservingRunner {
        leased: leased.clone(),
    }));
    let automation = harness.seed(Some(1_767_596_400));

    run_due(&harness.state).await.expect("pass");

    assert_eq!(
        *leased.lock(),
        Some(true),
        "the run worked without holding a lease on its operation"
    );

    let runs = harness.runs_of(automation.id);
    assert_eq!(runs[0].state, "succeeded");
    let (state, code) = harness.operation_state(runs[0].id);
    assert_eq!(state, "succeeded");
    assert_eq!(code, None);
    let database = harness.state.database.as_ref().expect("database");
    let leased: i64 = database
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM operations WHERE lease_owner IS NOT NULL",
            [],
            |row| row.get(0),
        )
        .expect("count");
    assert_eq!(leased, 0, "the lease outlived the run");
}

include!("tests/lifetime.rs");
