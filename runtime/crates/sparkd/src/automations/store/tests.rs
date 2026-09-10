use super::*;

fn mem() -> Connection {
    let mut conn = Connection::open_in_memory().expect("memory database");
    crate::migration::migrate(&mut conn).expect("migrations");
    conn
}

fn owner(conn: &Connection) -> Uuid {
    let id = Uuid::new_v4();
    crate::store::insert_device(
        conn,
        &id,
        "phone",
        "ios",
        b"spki",
        &format!("fp-{id}"),
        "owner",
    )
    .expect("device");
    id
}

fn draft(owner: Uuid) -> Automation {
    Automation {
        id: Uuid::new_v4(),
        owner_device_id: owner,
        name: "Daily brief".to_owned(),
        instructions: "Tell me what happened overnight.".to_owned(),
        schedule_preset: "daily".to_owned(),
        schedule_expression: "0 7 * * *".to_owned(),
        timezone: "Europe/London".to_owned(),
        model_id: "a-model".to_owned(),
        profile_id: None,
        web_access: true,
        notify: true,
        enabled: true,
        next_run_at: None,
        created_at: 0,
        updated_at: 0,
    }
}

#[test]
fn an_automation_round_trips_with_everything_the_owner_chose() {
    let conn = mem();
    let owner = owner(&conn);
    let draft = draft(owner);
    let stored = insert(
        &conn,
        Uuid::new_v4(),
        owner,
        &draft,
        Some(1_780_000_000),
        100,
    )
    .expect("insert");
    assert_eq!(stored.name, "Daily brief");
    assert_eq!(stored.timezone, "Europe/London");
    assert!(stored.web_access);
    assert_eq!(stored.next_run_at, Some(1_780_000_000));
    assert_eq!(get(&conn, draft.id).expect("get"), Some(stored.clone()));
    assert_eq!(list(&conn).expect("list"), vec![stored]);
    assert_eq!(count(&conn).expect("count"), 1);
    assert!(delete(&conn, draft.id).expect("delete"));
    assert_eq!(count(&conn).expect("count"), 0);
}

#[test]
fn one_slot_can_only_be_claimed_once_however_often_it_is_tried() {
    let conn = mem();
    let owner = owner(&conn);
    let draft = draft(owner);
    insert(&conn, Uuid::new_v4(), owner, &draft, Some(500), 100).expect("insert");
    let first = claim_run(&conn, draft.id, "schedule", Some(500), 500).expect("first claim");
    assert!(first.is_some());
    let second = claim_run(&conn, draft.id, "schedule", Some(500), 501).expect("second claim");
    assert_eq!(second, None, "the same slot was claimed twice");
    assert_eq!(runs(&conn, draft.id).expect("runs").len(), 1);
}

/// BH-24: manual runs had no concurrency guard at all, so N posts gave N concurrent runs.
#[test]
fn bh_24_only_one_run_of_an_automation_is_ever_in_flight() {
    let conn = mem();
    let owner = owner(&conn);
    let draft = draft(owner);
    insert(&conn, Uuid::new_v4(), owner, &draft, Some(500), 100).expect("insert");
    let scheduled = claim_run(&conn, draft.id, "schedule", Some(500), 500)
        .expect("slot")
        .expect("id");
    assert_eq!(
        in_flight(&conn, draft.id).expect("in flight"),
        Some(scheduled)
    );
    assert_eq!(
        claim_run(&conn, draft.id, "manual", None, 501).expect("manual"),
        None,
        "a manual run started while a scheduled one was still running"
    );
    finish_run(&conn, scheduled, "succeeded", None, None, &[], 502).expect("settle");
    assert_eq!(in_flight(&conn, draft.id).expect("in flight"), None);

    let manual = claim_run(&conn, draft.id, "manual", None, 503)
        .expect("manual")
        .expect("id");
    assert_eq!(
        claim_run(&conn, draft.id, "manual", None, 504).expect("second manual"),
        None,
        "two manual runs of one automation were accepted"
    );
    assert_eq!(
        claim_run(&conn, draft.id, "schedule", Some(600), 505).expect("scheduled"),
        None,
        "a scheduled run started while a manual one was still running"
    );
    finish_run(&conn, manual, "succeeded", None, None, &[], 506).expect("settle");
    assert!(
        claim_run(&conn, draft.id, "schedule", Some(600), 507)
            .expect("scheduled")
            .is_some()
    );
    assert_eq!(runs(&conn, draft.id).expect("runs").len(), 3);
}

/// Another automation is never blocked by the one that is running.
#[test]
fn bh_24_the_in_flight_guard_is_per_automation() {
    let conn = mem();
    let owner = owner(&conn);
    let first = draft(owner);
    let mut second = draft(owner);
    second.id = Uuid::new_v4();
    insert(&conn, Uuid::new_v4(), owner, &first, Some(500), 100).expect("insert");
    insert(&conn, Uuid::new_v4(), owner, &second, Some(500), 100).expect("insert");
    assert!(
        claim_run(&conn, first.id, "manual", None, 500)
            .expect("first")
            .is_some()
    );
    assert!(
        claim_run(&conn, second.id, "manual", None, 500)
            .expect("second")
            .is_some()
    );
}

#[test]
fn a_settled_run_keeps_its_result_and_is_never_settled_twice() {
    let conn = mem();
    let owner = owner(&conn);
    let draft = draft(owner);
    insert(&conn, Uuid::new_v4(), owner, &draft, Some(500), 100).expect("insert");
    let run_id = claim_run(&conn, draft.id, "manual", None, 500)
        .expect("claim")
        .expect("id");
    let calls = vec![serde_json::json!({"index": 0, "tool": "web_search"})];
    finish_run(
        &conn,
        run_id,
        "succeeded",
        Some("Here it is."),
        None,
        &calls,
        600,
    )
    .expect("finish");
    finish_run(&conn, run_id, "failed", None, Some("LATE"), &[], 700).expect("second finish");
    let stored = run(&conn, run_id).expect("read").expect("row");
    assert_eq!(stored.state, "succeeded");
    assert_eq!(stored.result_text.as_deref(), Some("Here it is."));
    assert_eq!(stored.finished_at, Some(600));
    assert_eq!(stored.tool_calls, calls);
    assert_eq!(
        last_run(&conn, draft.id).expect("last"),
        Some((500, "succeeded".to_owned()))
    );
}

#[test]
fn the_next_slot_is_read_in_the_automations_own_zone() {
    // 2026-01-05T00:00:00Z, winter in London, so 07:00 local is 07:00 UTC.
    let winter = next_slot("0 7 * * *", "Europe/London", 1_767_571_200).expect("slot");
    assert_eq!(winter, Some(1_767_596_400));
    // 2026-07-05T00:00:00Z, summer in London, so 07:00 local is 06:00 UTC.
    let summer = next_slot("0 7 * * *", "Europe/London", 1_783_209_600).expect("slot");
    assert_eq!(summer, Some(1_783_231_200));
    assert_eq!(
        next_slot("nonsense", "Europe/London", 0),
        Err("AUTOMATION_SCHEDULE_INVALID")
    );
    assert_eq!(
        next_slot("0 7 * * *", "Mars/Olympus", 0),
        Err("AUTOMATION_TIMEZONE_UNKNOWN")
    );
}
