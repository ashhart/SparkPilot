#[tokio::test]
async fn every_policy_refusal_names_its_reason_and_is_counted() {
    let household = household(&evening_policy());

    let (status, body) = chat(&household, "gpt-oss-120b").await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(error_code(&body), "GUEST_MODEL_NOT_ALLOWED");

    household.clock.set(
        time::OffsetDateTime::from_unix_timestamp(SUMMER_EVENING - 6 * 3_600).expect("instant"),
    );
    let (status, body) = chat(&household, "qwen3-8b").await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(error_code(&body), "GUEST_OUTSIDE_HOURS");
    household.clock.set(
        time::OffsetDateTime::from_unix_timestamp(SUMMER_EVENING).expect("instant"),
    );

    {
        let connection = household.state.database.as_ref().expect("db").lock();
        sparkd::guest::record_request(
            &connection,
            &household.guest.device_id,
            "2026-07-01",
            10_000,
            0,
            "2026-07-01T18:00:00Z",
        )
        .expect("spend the budget");
    }
    let (status, body) = chat(&household, "qwen3-8b").await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(error_code(&body), "GUEST_BUDGET_EXHAUSTED");

    for (state, code) in [
        (GrantState::Paused, "GUEST_ACCESS_PAUSED"),
        (GrantState::Revoked, "GUEST_ACCESS_REVOKED"),
    ] {
        set_state(&household, state);
        let (_, body) = chat(&household, "qwen3-8b").await;
        assert!(
            [code, "ROLE_FORBIDDEN"].contains(&error_code(&body).as_str()),
            "{state:?} produced {}",
            error_code(&body)
        );
    }

    let refusals = {
        let connection = household.state.database.as_ref().expect("db").lock();
        sparkd::guest::refusals_by_reason(
            &connection,
            &household.guest.device_id,
            &["2026-07-01".into()],
        )
        .expect("refusals")
    };
    assert_eq!(refusals.get("GUEST_MODEL_NOT_ALLOWED"), Some(&1));
    assert_eq!(refusals.get("GUEST_BUDGET_EXHAUSTED"), Some(&1));
    assert!(refusals.contains_key("GUEST_OUTSIDE_HOURS"));

    let audited = audit_reasons(&household, "guest.request.refused");
    assert!(audited.contains(&"GUEST_MODEL_NOT_ALLOWED".to_owned()));
    assert!(audited.contains(&"GUEST_BUDGET_EXHAUSTED".to_owned()));
}
