use super::*;

fn london() -> super::super::timezone::Timezone {
    super::super::timezone::Timezone::load("Europe/London").expect("Europe/London is installed")
}

fn at(text: &str) -> i64 {
    let date = time::OffsetDateTime::parse(text, &time::format_description::well_known::Rfc3339)
        .expect("test instant parses");
    date.unix_timestamp()
}

fn rendered(unix: i64, zone: &super::super::timezone::Timezone) -> String {
    let local = time::OffsetDateTime::from_unix_timestamp(unix + i64::from(zone.offset_at(unix)))
        .expect("in range");
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}",
        local.year(),
        u8::from(local.month()),
        local.day(),
        local.hour(),
        local.minute()
    )
}

#[test]
fn every_field_shape_the_app_can_produce_parses() {
    for expression in [
        "0 7 * * *",
        "30 6 * * 1-5",
        "0 */4 * * *",
        "15 9 * * 0",
        "0,30 8,20 * * *",
        "*/15 * * * *",
        "0 0 1 1 *",
        "59 23 31 12 *",
        "0 7 * * 1,3,5",
    ] {
        assert!(
            Schedule::parse(expression).is_ok(),
            "{expression} must parse"
        );
    }
}

#[test]
fn an_expression_the_parser_cannot_honour_is_refused_rather_than_stored() {
    for expression in [
        "",
        "0 7 * *",
        "0 7 * * * *",
        "60 7 * * *",
        "0 24 * * *",
        "0 7 0 * *",
        "0 7 32 * *",
        "0 7 * 0 *",
        "0 7 * 13 *",
        "0 7 * * 7",
        "*/0 7 * * *",
        "0 */0 * * *",
        "a 7 * * *",
        "5-1 7 * * *",
        "0 7 * * mon",
        "0 7 * * 1-",
        "0 7 * * -1",
        "  ",
        "0 7 * * *; rm -rf /",
    ] {
        assert!(
            Schedule::parse(expression).is_err(),
            "{expression:?} must be refused"
        );
    }
}

#[test]
fn the_presets_the_app_offers_compose_expressions_the_parser_accepts() {
    assert_eq!(Schedule::daily(7, 0).expression(), "0 7 * * *");
    assert_eq!(Schedule::weekdays(6, 30).expression(), "30 6 * * 1-5");
    assert_eq!(Schedule::every_n_hours(4, 15).expression(), "15 */4 * * *");
    assert_eq!(Schedule::weekly(0, 9, 15).expression(), "15 9 * * 0");
    for schedule in [
        Schedule::daily(7, 0),
        Schedule::weekdays(6, 30),
        Schedule::every_n_hours(4, 15),
        Schedule::weekly(0, 9, 15),
    ] {
        assert!(Schedule::parse(schedule.expression()).is_ok());
    }
}

#[test]
fn a_daily_schedule_fires_at_the_owners_local_hour_in_both_seasons() {
    let zone = london();
    let daily = Schedule::parse("0 7 * * *").expect("valid");

    let winter = daily
        .next_after(at("2026-01-15T12:00:00Z"), &zone)
        .expect("a next run");
    assert_eq!(rendered(winter, &zone), "2026-01-16 07:00");
    assert_eq!(winter, at("2026-01-16T07:00:00Z"));

    let summer = daily
        .next_after(at("2026-06-15T12:00:00Z"), &zone)
        .expect("a next run");
    assert_eq!(rendered(summer, &zone), "2026-06-16 07:00");
    // 07:00 local in summer is 06:00 UTC; a schedule stored in UTC would be an hour late.
    assert_eq!(summer, at("2026-06-16T06:00:00Z"));
}

#[test]
fn the_daily_slot_stays_at_the_same_local_time_across_the_spring_forward_weekend() {
    let zone = london();
    let daily = Schedule::parse("0 7 * * *").expect("valid");
    let saturday = daily
        .next_after(at("2026-03-28T12:00:00Z"), &zone)
        .expect("a next run");
    assert_eq!(rendered(saturday, &zone), "2026-03-29 07:00");
    let sunday = daily.next_after(saturday, &zone).expect("a next run");
    assert_eq!(rendered(sunday, &zone), "2026-03-30 07:00");
    assert_eq!(saturday - at("2026-03-28T07:00:00Z"), 23 * 3_600);
}

#[test]
fn a_slot_inside_the_spring_forward_gap_still_produces_exactly_one_run() {
    let zone = london();
    let inside_the_gap = Schedule::parse("30 1 * * *").expect("valid");
    let fired = inside_the_gap
        .next_after(at("2026-03-28T12:00:00Z"), &zone)
        .expect("a next run");
    assert_eq!(fired, at("2026-03-29T01:00:00Z"));
    let following = inside_the_gap.next_after(fired, &zone).expect("a next run");
    assert_eq!(rendered(following, &zone), "2026-03-30 01:30");
    assert!(following > fired);
}

#[test]
fn a_slot_inside_the_fall_back_overlap_produces_exactly_one_run() {
    let zone = london();
    let ambiguous = Schedule::parse("30 1 * * *").expect("valid");
    let fired = ambiguous
        .next_after(at("2026-10-24T12:00:00Z"), &zone)
        .expect("a next run");
    assert_eq!(rendered(fired, &zone), "2026-10-25 01:30");
    assert_eq!(fired, at("2026-10-25T00:30:00Z"));
    let following = ambiguous.next_after(fired, &zone).expect("a next run");
    assert_eq!(rendered(following, &zone), "2026-10-26 01:30");
    assert_eq!(following - fired, 25 * 3_600);
}

#[test]
fn weekdays_skips_the_weekend_and_weekly_lands_on_its_own_day() {
    let zone = london();
    let weekdays = Schedule::parse("30 6 * * 1-5").expect("valid");
    // 2026-01-16 is a Friday; the next weekday slot is the following Monday.
    let next = weekdays
        .next_after(at("2026-01-16T12:00:00Z"), &zone)
        .expect("a next run");
    assert_eq!(rendered(next, &zone), "2026-01-19 06:30");

    let sundays = Schedule::parse("15 9 * * 0").expect("valid");
    let sunday = sundays
        .next_after(at("2026-01-16T12:00:00Z"), &zone)
        .expect("a next run");
    assert_eq!(rendered(sunday, &zone), "2026-01-18 09:15");
}

#[test]
fn every_n_hours_walks_the_day_and_rolls_over_midnight() {
    let zone = london();
    let four_hourly = Schedule::parse("0 */4 * * *").expect("valid");
    let mut cursor = at("2026-01-15T12:00:00Z");
    let mut seen = Vec::new();
    for _ in 0..4 {
        cursor = four_hourly.next_after(cursor, &zone).expect("a next run");
        seen.push(rendered(cursor, &zone));
    }
    assert_eq!(
        seen,
        vec![
            "2026-01-15 16:00",
            "2026-01-15 20:00",
            "2026-01-16 00:00",
            "2026-01-16 04:00",
        ]
    );
}

#[test]
fn a_next_run_is_strictly_after_the_instant_it_is_asked_about() {
    let zone = london();
    let daily = Schedule::parse("0 7 * * *").expect("valid");
    let exact = at("2026-01-16T07:00:00Z");
    let next = daily.next_after(exact, &zone).expect("a next run");
    assert!(next > exact, "a slot must never fire twice for one instant");
    assert_eq!(rendered(next, &zone), "2026-01-17 07:00");
}

#[test]
fn day_of_month_and_day_of_week_together_match_either_day_as_cron_does() {
    let zone = london();
    // 2026-01-01 is a Thursday; the first of the month and every Monday both match.
    let either = Schedule::parse("0 7 1 * 1").expect("valid");
    let first = either
        .next_after(at("2026-01-01T00:00:00Z"), &zone)
        .expect("a next run");
    assert_eq!(rendered(first, &zone), "2026-01-01 07:00");
    let second = either.next_after(first, &zone).expect("a next run");
    assert_eq!(rendered(second, &zone), "2026-01-05 07:00");
}

#[test]
fn a_schedule_that_can_never_match_returns_nothing_rather_than_searching_forever() {
    let zone = london();
    let never = Schedule::parse("0 7 30 2 *").expect("valid");
    assert_eq!(never.next_after(at("2026-01-15T12:00:00Z"), &zone), None);
}
