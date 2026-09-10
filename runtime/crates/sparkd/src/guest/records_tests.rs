use super::*;

use crate::guest::policy::{HourWindow, WeeklySchedule};

fn database() -> rusqlite::Connection {
    let mut connection = rusqlite::Connection::open_in_memory().expect("memory database");
    crate::migration::migrate(&mut connection).expect("migrate");
    connection
}

fn seed_device(conn: &rusqlite::Connection, role: &str) -> uuid::Uuid {
    let id = uuid::Uuid::new_v4();
    crate::store::insert_device(
        conn,
        &id,
        "device",
        "ios",
        format!("spki-{id}").as_bytes(),
        &format!("fingerprint-{id}"),
        role,
    )
    .expect("insert device");
    id
}

fn seed_invitation(conn: &rusqlite::Connection, issuer: &uuid::Uuid) -> uuid::Uuid {
    let id = uuid::Uuid::new_v4();
    conn.execute(
        "INSERT INTO pairing_invitations
            (id, role, nonce_hash, issued_by_device_id, issued_at, expires_at, signed_payload_json)
         VALUES (?1, 'guest', ?2, ?3, '2026-01-01T00:00:00Z', '2026-01-08T00:00:00Z', '{}')",
        rusqlite::params![id.to_string(), id.as_bytes().to_vec(), issuer.to_string()],
    )
    .expect("insert invitation");
    id
}

fn sample_policy() -> GuestPolicy {
    GuestPolicy {
        state: GrantState::Pending,
        display_name: "Sam".into(),
        allowed_models: vec!["qwen3-8b".into()],
        allowed_hours: WeeklySchedule::everyday(&[HourWindow {
            start_minute: 540,
            end_minute: 1320,
        }]),
        time_zone: "Europe/London".into(),
        max_concurrent_requests: 2,
        daily_token_budget: 20_000,
        expires_at: None,
    }
}

fn seeded_grant(conn: &rusqlite::Connection) -> (uuid::Uuid, uuid::Uuid) {
    let owner = seed_device(conn, "owner");
    let invitation_id = seed_invitation(conn, &owner);
    insert_grant(
        conn,
        &invitation_id,
        &owner,
        &sample_policy(),
        "2026-01-01T00:00:00Z",
    )
    .expect("insert grant");
    (invitation_id, owner)
}

#[test]
fn a_grant_is_written_with_its_policy_and_read_back_whole() {
    let conn = database();
    let (invitation_id, owner) = seeded_grant(&conn);
    let stored = grant_by_invitation(&conn, &invitation_id)
        .expect("read")
        .expect("row");
    assert_eq!(stored.policy, sample_policy());
    assert_eq!(stored.created_by_device_id, owner);
    assert_eq!(stored.device_id, None);
    assert_eq!(stored.policy.state, GrantState::Pending);
}

#[test]
fn claiming_binds_the_grant_to_the_device_and_leaves_it_awaiting_the_owner() {
    let conn = database();
    let (invitation_id, _) = seeded_grant(&conn);
    let guest = seed_device(&conn, "observer");
    bind_grant_to_device(&conn, &invitation_id, &guest, "2026-01-02T10:00:00Z").expect("bind");

    let stored = grant_for_device(&conn, &guest).expect("read").expect("row");
    assert_eq!(stored.device_id, Some(guest));
    assert_eq!(stored.policy.state, GrantState::Pending);
    assert_eq!(stored.joined_at.as_deref(), Some("2026-01-02T10:00:00Z"));
}

#[test]
fn one_invitation_binds_exactly_one_device() {
    let conn = database();
    let (invitation_id, _) = seeded_grant(&conn);
    let first = seed_device(&conn, "observer");
    let second = seed_device(&conn, "observer");
    bind_grant_to_device(&conn, &invitation_id, &first, "2026-01-02T10:00:00Z").expect("bind");
    assert!(
        bind_grant_to_device(&conn, &invitation_id, &second, "2026-01-02T11:00:00Z").is_err(),
        "a bound grant must not be rebound"
    );
    assert!(grant_for_device(&conn, &second).expect("read").is_none());
}

#[test]
fn a_grant_pins_the_device_to_guest_and_withdrawing_it_never_lifts_the_pin() {
    use crate::capability::Role;
    let conn = database();
    let (invitation_id, _) = seeded_grant(&conn);
    let guest = seed_device(&conn, "observer");
    assert_eq!(
        effective_role(&conn, &guest, Role::Observer).expect("role"),
        None
    );

    bind_grant_to_device(&conn, &invitation_id, &guest, "2026-01-02T10:00:00Z").expect("bind");
    assert_eq!(
        effective_role(&conn, &guest, Role::Observer).expect("role"),
        Some(Role::Guest)
    );

    // BH-21: a half-finished revocation leaves this row revoked and the device row untouched.
    set_grant_state(&conn, &guest, GrantState::Revoked, "2026-01-03T10:00:00Z").expect("revoke");
    assert_eq!(
        effective_role(&conn, &guest, Role::Observer).expect("role"),
        Some(Role::Guest),
        "withdrawing a grant must not raise the device above guest"
    );
    assert_eq!(
        effective_role(&conn, &guest, Role::User).expect("role"),
        None,
        "an owner who deliberately raised the device afterwards keeps that decision"
    );
}

#[test]
fn activation_and_pause_move_the_state_and_stamp_the_confirmation() {
    let conn = database();
    let (invitation_id, _) = seeded_grant(&conn);
    let guest = seed_device(&conn, "observer");
    bind_grant_to_device(&conn, &invitation_id, &guest, "2026-01-02T10:00:00Z").expect("bind");

    set_grant_state(&conn, &guest, GrantState::Active, "2026-01-02T10:05:00Z").expect("activate");
    let stored = grant_for_device(&conn, &guest).expect("read").expect("row");
    assert_eq!(stored.policy.state, GrantState::Active);
    assert_eq!(stored.confirmed_at.as_deref(), Some("2026-01-02T10:05:00Z"));

    set_grant_state(&conn, &guest, GrantState::Paused, "2026-01-02T11:00:00Z").expect("pause");
    let paused = grant_for_device(&conn, &guest).expect("read").expect("row");
    assert_eq!(paused.policy.state, GrantState::Paused);
    assert_eq!(
        paused.confirmed_at.as_deref(),
        Some("2026-01-02T10:05:00Z"),
        "pausing does not erase when the owner confirmed"
    );
}

#[test]
fn a_revoked_grant_never_returns_to_service() {
    let conn = database();
    let (invitation_id, _) = seeded_grant(&conn);
    let guest = seed_device(&conn, "observer");
    bind_grant_to_device(&conn, &invitation_id, &guest, "2026-01-02T10:00:00Z").expect("bind");
    set_grant_state(&conn, &guest, GrantState::Revoked, "2026-01-03T10:00:00Z").expect("revoke");
    assert!(
        set_grant_state(&conn, &guest, GrantState::Active, "2026-01-04T10:00:00Z").is_err(),
        "revocation is final"
    );
}

#[test]
fn usage_accumulates_by_local_day_and_the_budget_reads_only_today() {
    let conn = database();
    let (invitation_id, _) = seeded_grant(&conn);
    let guest = seed_device(&conn, "observer");
    bind_grant_to_device(&conn, &invitation_id, &guest, "2026-01-02T10:00:00Z").expect("bind");

    record_request(
        &conn,
        &guest,
        "2026-01-02",
        100,
        250,
        "2026-01-02T10:10:00Z",
    )
    .expect("record");
    record_request(&conn, &guest, "2026-01-02", 40, 60, "2026-01-02T10:20:00Z").expect("record");
    record_request(&conn, &guest, "2026-01-03", 7, 3, "2026-01-03T09:00:00Z").expect("record");

    assert_eq!(
        tokens_used_on(&conn, &guest, "2026-01-02").expect("today"),
        450
    );
    assert_eq!(
        tokens_used_on(&conn, &guest, "2026-01-03").expect("today"),
        10
    );
    assert_eq!(
        tokens_used_on(&conn, &guest, "2026-01-04").expect("today"),
        0
    );

    let day = daily_usage(&conn, &guest, "2026-01-02").expect("usage");
    assert_eq!(
        (day.requests, day.prompt_tokens, day.completion_tokens),
        (2, 140, 310)
    );
}

#[test]
fn refusals_are_counted_per_reason_and_rolled_into_the_day() {
    let conn = database();
    let (invitation_id, _) = seeded_grant(&conn);
    let guest = seed_device(&conn, "observer");
    bind_grant_to_device(&conn, &invitation_id, &guest, "2026-01-02T10:00:00Z").expect("bind");

    record_refusal(
        &conn,
        &guest,
        "2026-01-02",
        "GUEST_OUTSIDE_HOURS",
        "2026-01-02T02:00:00Z",
    )
    .expect("record");
    record_refusal(
        &conn,
        &guest,
        "2026-01-02",
        "GUEST_OUTSIDE_HOURS",
        "2026-01-02T02:05:00Z",
    )
    .expect("record");
    record_refusal(
        &conn,
        &guest,
        "2026-01-02",
        "GUEST_MODEL_NOT_ALLOWED",
        "2026-01-02T12:00:00Z",
    )
    .expect("record");

    assert_eq!(
        daily_usage(&conn, &guest, "2026-01-02")
            .expect("usage")
            .refusals,
        3
    );
    let reasons = refusals_by_reason(&conn, &guest, &["2026-01-02".into()]).expect("reasons");
    assert_eq!(reasons.get("GUEST_OUTSIDE_HOURS"), Some(&2));
    assert_eq!(reasons.get("GUEST_MODEL_NOT_ALLOWED"), Some(&1));
}

#[test]
fn a_weeks_totals_sum_the_days_the_owner_asked_for() {
    let conn = database();
    let (invitation_id, _) = seeded_grant(&conn);
    let guest = seed_device(&conn, "observer");
    bind_grant_to_device(&conn, &invitation_id, &guest, "2026-01-02T10:00:00Z").expect("bind");
    for (day, tokens) in [
        ("2026-01-01", 10u64),
        ("2026-01-02", 20),
        ("2026-01-03", 30),
    ] {
        record_request(&conn, &guest, day, tokens, 0, "2026-01-03T00:00:00Z").expect("record");
    }
    let week =
        usage_over(&conn, &guest, &["2026-01-02".into(), "2026-01-03".into()]).expect("week");
    assert_eq!(week.prompt_tokens, 50);
    assert_eq!(week.requests, 2);
}

#[test]
fn listing_grants_returns_every_guest_including_the_revoked_ones() {
    let conn = database();
    let owner = seed_device(&conn, "owner");
    for name in ["Sam", "Robin"] {
        let invitation_id = seed_invitation(&conn, &owner);
        let mut policy = sample_policy();
        policy.display_name = name.into();
        insert_grant(
            &conn,
            &invitation_id,
            &owner,
            &policy,
            "2026-01-01T00:00:00Z",
        )
        .expect("insert");
    }
    let listed = list_grants(&conn).expect("list");
    assert_eq!(listed.len(), 2);
    assert!(
        listed
            .iter()
            .any(|grant| grant.policy.display_name == "Robin")
    );
}

#[test]
fn editing_limits_replaces_the_policy_without_touching_the_lifecycle() {
    let conn = database();
    let (invitation_id, _) = seeded_grant(&conn);
    let guest = seed_device(&conn, "observer");
    bind_grant_to_device(&conn, &invitation_id, &guest, "2026-01-02T10:00:00Z").expect("bind");
    set_grant_state(&conn, &guest, GrantState::Active, "2026-01-02T10:05:00Z").expect("activate");

    let mut edited = sample_policy();
    edited.allowed_models = vec!["qwen3-4b".into(), "gemma3-12b".into()];
    edited.daily_token_budget = 5_000;
    update_policy(&conn, &guest, &edited, "2026-01-02T12:00:00Z").expect("update");

    let stored = grant_for_device(&conn, &guest).expect("read").expect("row");
    assert_eq!(stored.policy.allowed_models, edited.allowed_models);
    assert_eq!(stored.policy.daily_token_budget, 5_000);
    assert_eq!(
        stored.policy.state,
        GrantState::Active,
        "an edit is not a pause"
    );
}
