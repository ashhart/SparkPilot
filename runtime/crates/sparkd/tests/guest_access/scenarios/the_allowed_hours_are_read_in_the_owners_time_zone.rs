#[tokio::test]
async fn the_allowed_hours_are_read_in_the_owners_time_zone() {
    let household = household(&evening_policy());
    // 17:30 UTC is 18:30 in London while summer time is in force, so the evening window is open.
    household.clock.set(
        time::OffsetDateTime::from_unix_timestamp(1_782_927_000).expect("summer instant"),
    );
    let (_, body) = chat(&household, "qwen3-8b").await;
    assert_ne!(error_code(&body), "GUEST_OUTSIDE_HOURS");

    // The same 17:30 UTC in December is 17:30 in London, half an hour before the window opens.
    household.clock.set(
        time::OffsetDateTime::from_unix_timestamp(1_796_232_600).expect("winter instant"),
    );
    let (status, body) = chat(&household, "qwen3-8b").await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(error_code(&body), "GUEST_OUTSIDE_HOURS");
}
