/// BH-37: cancelling a run was accepted, silently ignored, and then reported as succeeded.
#[tokio::test]
async fn bh_37_a_cancelled_run_does_not_report_success() {
    let harness = harness(1_767_596_400);
    let automation = harness.seed(Some(1_767_596_400));
    let database = harness.state.database.clone().expect("database");
    let run_id = {
        let conn = database.lock();
        store::claim_run(&conn, automation.id, "manual", None, 1_767_596_400)
            .expect("claim")
            .expect("id")
    };
    let operation = {
        let conn = database.lock();
        let id = harness
            .state
            .jobs
            .create(
                &conn,
                RUN_KIND,
                automation.owner_device_id,
                Some(&automation.name),
                "{}",
            )
            .expect("operation");
        store::attach_operation(&conn, run_id, id).expect("attach");
        id
    };
    {
        let conn = database.lock();
        assert!(
            harness
                .state
                .jobs
                .cancel_requested(&conn, operation)
                .expect("cancel")
        );
    }

    execute(&harness.state, automation.clone(), run_id).await;

    assert!(
        harness.runs.lock().is_empty(),
        "a cancelled run still asked the model"
    );
    let runs = harness.runs_of(automation.id);
    assert_eq!(runs[0].state, "failed", "a cancelled run reported success");
    assert_eq!(runs[0].error_code.as_deref(), Some("OPERATION_CANCELLED"));
    let (state, code) = harness.operation_state(run_id);
    assert_eq!(state, "cancelled", "the operation reported {state}");
    assert_eq!(code.as_deref(), Some("OPERATION_CANCELLED"));
}

/// BH-25: a panic in the runner used to kill the scheduler for the life of the process.
#[tokio::test]
async fn bh_25_a_panicking_runner_fails_its_run_and_leaves_the_scheduler_working() {
    let mut harness = harness(1_767_596_400);
    let left = Arc::new(Mutex::new(1usize));
    harness.state.automations = AutomationService::with_runner(Arc::new(PanickingRunner {
        left: left.clone(),
        runs: harness.runs.clone(),
    }));
    let automation = harness.seed(Some(1_767_596_400));

    run_due(&harness.state).await.expect("the pass survived");

    let runs = harness.runs_of(automation.id);
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].state, "failed");
    assert_eq!(
        runs[0].error_code.as_deref(),
        Some("AUTOMATION_RUN_PANICKED")
    );
    let (state, code) = harness.operation_state(runs[0].id);
    assert_eq!(state, "failed", "the operation was left running");
    assert_eq!(code.as_deref(), Some("AUTOMATION_RUN_PANICKED"));
    let database = harness.state.database.as_ref().expect("database");
    let panicked: i64 = database
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM events WHERE event_type = 'automation.run.panicked'",
            [],
            |row| row.get(0),
        )
        .expect("event");
    assert_eq!(panicked, 1, "the panic was not published");

    // The next slot still fires: the scheduler was not lost with the run.
    harness
        .clock
        .set(time::OffsetDateTime::from_unix_timestamp(1_767_596_400 + 86_400).expect("in range"));
    run_due(&harness.state).await.expect("the next pass runs");
    assert_eq!(harness.runs.lock().len(), 1, "no run happened afterwards");
    assert_eq!(*left.lock(), 0);
}

#[test]
fn manual_and_scheduled_runs_share_one_in_flight_claim() {
    let harness = harness(1_767_596_400);
    let automation = harness.seed(None);
    let conn = harness.state.database.as_ref().unwrap().lock();
    assert!(
        store::claim_run(&conn, automation.id, "manual", None, 1)
            .unwrap()
            .is_some()
    );
    assert!(
        store::claim_run(&conn, automation.id, "manual", None, 2)
            .unwrap()
            .is_none()
    );
    assert!(
        store::claim_run(&conn, automation.id, "schedule", Some(2), 2)
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn one_pass_skips_the_whole_downtime_without_replaying_old_slots() {
    let now = 1_767_596_400 + 30 * 86_400;
    let harness = harness(now);
    let automation = harness.seed(Some(1_767_596_400));
    run_due(&harness.state).await.unwrap();
    assert!(harness.reload(automation.id).next_run_at.unwrap() > now);
    assert!(harness.runs.lock().is_empty());
}

#[derive(Debug)]
struct PanicRunner;
#[async_trait::async_trait]
impl AutomationRunner for PanicRunner {
    async fn run(&self, _: &AppState, _: &Automation) -> RunOutcome {
        panic!("injected runner panic")
    }
}

#[tokio::test]
async fn a_runner_panic_is_a_failed_run_and_does_not_kill_the_scheduler() {
    use futures::FutureExt;
    let mut harness = harness(1_767_596_400);
    let automation = harness.seed(Some(1_767_596_400));
    harness.state.automations.runner = Some(Arc::new(PanicRunner));
    let result = std::panic::AssertUnwindSafe(run_due(&harness.state))
        .catch_unwind()
        .await;
    assert!(result.is_ok());
    let runs = harness.runs_of(automation.id);
    assert_eq!(runs[0].state, "failed");
    let operation = crate::store::operation_row(
        &harness.state.database.as_ref().unwrap().lock(),
        runs[0].operation_id.unwrap(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(operation.state, "failed");
}

#[tokio::test]
async fn a_missing_runner_settles_the_operation_as_well_as_the_run() {
    let mut harness = harness(1_767_596_400);
    let automation = harness.seed(Some(1_767_596_400));
    harness.state.automations.runner = None;
    run_due(&harness.state).await.unwrap();
    let runs = harness.runs_of(automation.id);
    let operation = crate::store::operation_row(
        &harness.state.database.as_ref().unwrap().lock(),
        runs[0].operation_id.unwrap(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(runs[0].state, "failed");
    assert_eq!(operation.state, "failed");
}
