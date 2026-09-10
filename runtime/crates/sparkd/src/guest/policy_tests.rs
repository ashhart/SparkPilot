use super::*;

use crate::guest::timezone::TimeZone;

/// Great Britain with the 2026 transitions, so schedule tests exercise both clock changes.
fn london() -> TimeZone {
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"TZif");
    bytes.push(0);
    bytes.extend_from_slice(&[0u8; 15]);
    for count in [0u32, 0, 0, 2, 2, 2] {
        bytes.extend_from_slice(&count.to_be_bytes());
    }
    for transition in [1_774_746_000i32, 1_792_890_000] {
        bytes.extend_from_slice(&transition.to_be_bytes());
    }
    bytes.extend_from_slice(&[1u8, 0]);
    bytes.extend_from_slice(&0i32.to_be_bytes());
    bytes.extend_from_slice(&[0u8, 0]);
    bytes.extend_from_slice(&3600i32.to_be_bytes());
    bytes.extend_from_slice(&[1u8, 1]);
    bytes.extend_from_slice(b"XX");
    TimeZone::parse(&bytes).expect("zone")
}

fn evening_policy() -> GuestPolicy {
    GuestPolicy {
        state: GrantState::Active,
        display_name: "Sam".into(),
        allowed_models: vec!["qwen3-8b".into()],
        allowed_hours: WeeklySchedule::everyday(&[HourWindow {
            start_minute: 1080,
            end_minute: 1380,
        }]),
        time_zone: "Europe/London".into(),
        max_concurrent_requests: 1,
        daily_token_budget: 10_000,
        expires_at: None,
    }
}

fn attempt(now_unix: i64) -> GuestAttempt<'static> {
    GuestAttempt {
        model_id: "qwen3-8b",
        now_unix,
        active_requests: 0,
        tokens_used_today: 0,
    }
}

/// 2026-07-01T19:00+01:00 (BST): inside an 18:00-23:00 window.
const SUMMER_EVENING: i64 = 1_782_928_800;

#[test]
fn an_allowed_model_inside_the_window_and_the_budget_is_permitted() {
    let decision = evaluate(&evening_policy(), &london(), &attempt(SUMMER_EVENING));
    assert_eq!(decision, Ok(()));
}

#[test]
fn a_model_outside_the_allowed_list_is_refused_by_name() {
    let mut request = attempt(SUMMER_EVENING);
    request.model_id = "gpt-oss-120b";
    assert_eq!(
        evaluate(&evening_policy(), &london(), &request),
        Err(GuestRefusal::ModelNotAllowed)
    );
    assert_eq!(
        GuestRefusal::ModelNotAllowed.code(),
        "GUEST_MODEL_NOT_ALLOWED"
    );
}

#[test]
fn an_empty_model_list_permits_nothing_at_all() {
    let mut policy = evening_policy();
    policy.allowed_models.clear();
    assert_eq!(
        evaluate(&policy, &london(), &attempt(SUMMER_EVENING)),
        Err(GuestRefusal::ModelNotAllowed)
    );
}

#[test]
fn the_same_utc_instant_falls_differently_on_either_side_of_a_clock_change() {
    let policy = evening_policy();
    let zone = london();
    // 17:30 UTC: inside the window in summer (18:30 local), outside it in winter (17:30 local).
    let summer = 1_782_927_000;
    let winter = 1_796_232_600;
    assert_eq!(evaluate(&policy, &zone, &attempt(summer)), Ok(()));
    assert_eq!(
        evaluate(&policy, &zone, &attempt(winter)),
        Err(GuestRefusal::OutsideHours)
    );
}

#[test]
fn a_weekday_only_schedule_refuses_the_weekend() {
    let mut policy = evening_policy();
    policy.allowed_hours = WeeklySchedule::weekdays(&[HourWindow {
        start_minute: 0,
        end_minute: 1440,
    }]);
    // 2026-07-01 is a Wednesday; 2026-07-04 is the Saturday that follows.
    assert_eq!(
        evaluate(&policy, &london(), &attempt(SUMMER_EVENING)),
        Ok(())
    );
    assert_eq!(
        evaluate(&policy, &london(), &attempt(SUMMER_EVENING + 3 * 86_400)),
        Err(GuestRefusal::OutsideHours)
    );
}

#[test]
fn a_window_end_is_exclusive_so_midnight_belongs_to_the_next_day() {
    let mut policy = evening_policy();
    policy.allowed_hours = WeeklySchedule::everyday(&[HourWindow {
        start_minute: 0,
        end_minute: 60,
    }]);
    let zone = london();
    let start = zone.local_day_start(&zone.local_at(SUMMER_EVENING).expect("local"));
    assert_eq!(evaluate(&policy, &zone, &attempt(start)), Ok(()));
    assert_eq!(evaluate(&policy, &zone, &attempt(start + 3_599)), Ok(()));
    assert_eq!(
        evaluate(&policy, &zone, &attempt(start + 3_600)),
        Err(GuestRefusal::OutsideHours)
    );
}

#[test]
fn a_spent_daily_budget_refuses_until_local_midnight() {
    let policy = evening_policy();
    let mut request = attempt(SUMMER_EVENING);
    request.tokens_used_today = 9_999;
    assert_eq!(evaluate(&policy, &london(), &request), Ok(()));
    request.tokens_used_today = 10_000;
    assert_eq!(
        evaluate(&policy, &london(), &request),
        Err(GuestRefusal::BudgetExhausted)
    );
    assert_eq!(
        GuestRefusal::BudgetExhausted.code(),
        "GUEST_BUDGET_EXHAUSTED"
    );
}

#[test]
fn concurrent_requests_are_capped_per_guest() {
    let policy = evening_policy();
    let mut request = attempt(SUMMER_EVENING);
    request.active_requests = 1;
    assert_eq!(
        evaluate(&policy, &london(), &request),
        Err(GuestRefusal::ConcurrencyLimit)
    );
}

#[test]
fn the_lifecycle_is_checked_before_anything_the_guest_could_change() {
    let mut request = attempt(SUMMER_EVENING);
    request.model_id = "not-allowed";
    request.tokens_used_today = u64::MAX;
    for (state, refusal) in [
        (GrantState::Revoked, GuestRefusal::Revoked),
        (GrantState::Pending, GuestRefusal::AwaitingOwner),
        (GrantState::Paused, GuestRefusal::Paused),
    ] {
        let mut policy = evening_policy();
        policy.state = state;
        assert_eq!(evaluate(&policy, &london(), &request), Err(refusal));
    }
}

#[test]
fn an_expired_grant_refuses_even_while_it_is_still_marked_active() {
    let mut policy = evening_policy();
    policy.expires_at = Some(SUMMER_EVENING - 1);
    assert_eq!(
        evaluate(&policy, &london(), &attempt(SUMMER_EVENING)),
        Err(GuestRefusal::Expired)
    );
    policy.expires_at = Some(SUMMER_EVENING + 1);
    assert_eq!(
        evaluate(&policy, &london(), &attempt(SUMMER_EVENING)),
        Ok(())
    );
}

#[test]
fn every_refusal_carries_a_documented_code_and_a_status() {
    for refusal in [
        GuestRefusal::AwaitingOwner,
        GuestRefusal::Paused,
        GuestRefusal::Revoked,
        GuestRefusal::Expired,
        GuestRefusal::ModelNotAllowed,
        GuestRefusal::OutsideHours,
        GuestRefusal::BudgetExhausted,
        GuestRefusal::ConcurrencyLimit,
        GuestRefusal::ScheduleUnavailable,
    ] {
        assert!(refusal.code().starts_with("GUEST_"), "{refusal:?}");
        assert!(!refusal.message().is_empty(), "{refusal:?}");
        assert!(refusal.status().is_client_error(), "{refusal:?}");
    }
}

#[test]
fn a_policy_the_owner_could_not_have_meant_is_refused_before_it_is_stored() {
    let mut policy = evening_policy();
    policy.max_concurrent_requests = 0;
    assert!(policy.validate().is_err());

    let mut policy = evening_policy();
    policy.daily_token_budget = 0;
    assert!(policy.validate().is_err());

    let mut policy = evening_policy();
    policy.allowed_models = vec!["a".into(); MAX_ALLOWED_MODELS + 1];
    assert!(policy.validate().is_err());

    let mut policy = evening_policy();
    policy.allowed_hours.days[0].windows = vec![HourWindow {
        start_minute: 600,
        end_minute: 600,
    }];
    assert!(policy.validate().is_err());

    let mut policy = evening_policy();
    policy.allowed_hours.days[0].windows = vec![
        HourWindow {
            start_minute: 0,
            end_minute: 600,
        },
        HourWindow {
            start_minute: 300,
            end_minute: 900,
        },
    ];
    assert!(policy.validate().is_err(), "overlapping windows");

    let mut policy = evening_policy();
    policy.allowed_hours.days[0].windows = vec![HourWindow {
        start_minute: 0,
        end_minute: 1441,
    }];
    assert!(policy.validate().is_err());

    let mut policy = evening_policy();
    policy.time_zone = "../../etc/passwd".into();
    assert!(policy.validate().is_err());

    assert!(evening_policy().validate().is_ok());
}

#[test]
fn a_schedule_round_trips_through_its_stored_json() {
    let policy = evening_policy();
    let encoded = serde_json::to_string(&policy.allowed_hours).expect("encode");
    let decoded: WeeklySchedule = serde_json::from_str(&encoded).expect("decode");
    assert_eq!(decoded, policy.allowed_hours);
}
