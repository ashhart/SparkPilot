fn claimed_operation(harness: &Harness, automation: &Automation) -> (Uuid, Uuid) {
    let conn = harness.state.database.as_ref().unwrap().lock();
    let run = store::claim_run(&conn, automation.id, "manual", None, 1_767_596_400)
        .unwrap()
        .unwrap();
    let operation = harness
        .state
        .jobs
        .create(
            &conn,
            RUN_KIND,
            automation.owner_device_id,
            Some(&automation.name),
            "{}",
        )
        .unwrap();
    store::attach_operation(&conn, run, operation).unwrap();
    (run, operation)
}

#[tokio::test]
async fn duplicate_execution_does_not_run_or_settle_another_workers_claim() {
    let harness = harness(1_767_596_400);
    let automation = harness.seed(None);
    let (run, operation) = claimed_operation(&harness, &automation);
    let lease = harness
        .state
        .jobs
        .acquire_lease(harness.state.database.clone().unwrap(), operation)
        .unwrap();
    execute(&harness.state, automation.clone(), run).await;
    assert!(
        harness.runs.lock().is_empty(),
        "a duplicate worker ran without owning the lease"
    );
    assert_eq!(harness.runs_of(automation.id)[0].state, "running");
    assert_eq!(harness.operation_state(run).0, "running");
    lease.fail("TEST_FINISHED").unwrap();
}

#[derive(Debug)]
struct WaitingRunner;

#[async_trait::async_trait]
impl AutomationRunner for WaitingRunner {
    async fn run(&self, _: &AppState, _: &Automation) -> RunOutcome {
        std::future::pending().await
    }
}

#[tokio::test]
async fn a_stalled_run_is_bounded_and_releases_its_operation() {
    let mut harness = harness(1_767_596_400);
    harness.state.automations = AutomationService::with_runner(Arc::new(WaitingRunner));
    let automation = harness.seed(None);
    let (run, _) = claimed_operation(&harness, &automation);
    tokio::time::timeout(
        std::time::Duration::from_secs(2),
        super::run::execute_with_limit(
            &harness.state,
            automation.clone(),
            run,
            std::time::Duration::from_millis(20),
        ),
    )
    .await
    .expect("deadline did not settle the run");
    assert_eq!(
        harness.operation_state(run),
        (
            "failed".to_owned(),
            Some("AUTOMATION_RUN_TIMED_OUT".to_owned())
        )
    );
    assert_eq!(
        harness.runs_of(automation.id)[0].error_code.as_deref(),
        Some("AUTOMATION_RUN_TIMED_OUT")
    );
}

#[tokio::test]
async fn cancellation_drops_a_stalled_model_call_without_waiting_for_its_answer() {
    let mut harness = harness(1_767_596_400);
    harness.state.automations = AutomationService::with_runner(Arc::new(WaitingRunner));
    let automation = harness.seed(None);
    let (run, operation) = claimed_operation(&harness, &automation);
    let working_state = harness.state.clone();
    let working_automation = automation.clone();
    let worker =
        tokio::spawn(async move { execute(&working_state, working_automation, run).await });
    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    harness
        .state
        .jobs
        .cancel_requested(&harness.state.database.as_ref().unwrap().lock(), operation)
        .unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(2), worker)
        .await
        .expect("cancellation stalled")
        .unwrap();
    assert_eq!(harness.operation_state(run).0, "cancelled");
    assert_eq!(
        harness.runs_of(automation.id)[0].error_code.as_deref(),
        Some("OPERATION_CANCELLED")
    );
}
