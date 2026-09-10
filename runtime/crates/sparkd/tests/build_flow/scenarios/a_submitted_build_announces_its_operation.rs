/// PLAN 60.2: `operation.created` must have a producer for every operation kind, `build.submit` included.
#[test]
fn a_submitted_build_announces_its_operation() {
    let harness = harness();
    let mut events = harness.state.events.subscribe();
    submit(&harness, &BuildRequirements::default());

    let mut created = Vec::new();
    while let Ok(event) = events.try_recv() {
        if event["type"] == "operation.created" {
            created.push(event);
        }
    }
    assert_eq!(created.len(), 1, "one submission, one announcement");
    assert_eq!(created[0]["payload"]["kind"], "build.submit");
    assert_eq!(created[0]["payload"]["state"], "queued");
}
