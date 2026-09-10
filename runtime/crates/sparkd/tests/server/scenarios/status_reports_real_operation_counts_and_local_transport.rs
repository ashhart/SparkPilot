#[tokio::test]
async fn status_reports_real_operation_counts_and_local_transport() {
    let (mut state, client) = test_state();
    let database = state.database.as_ref().expect("status database");
    let now = time::OffsetDateTime::parse(
        "2026-08-27T12:34:56.900000000Z",
        &time::format_description::well_known::Rfc3339,
    )
    .unwrap();
    state.clock = Arc::new(sparkd::clock::ManualUtcClock::new(now));
    let recent = now
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let boundary = (now - time::Duration::hours(24))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let just_old = (now - time::Duration::hours(24) - time::Duration::nanoseconds(1))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();

    {
        let conn = database.lock();
        for (state_name, timestamp) in [
            ("requested", recent.as_str()),
            ("validating", recent.as_str()),
            ("queued", recent.as_str()),
            ("running", recent.as_str()),
            ("cancelling", recent.as_str()),
            ("waiting_for_approval", recent.as_str()),
            ("failed", recent.as_str()),
            ("failed", boundary.as_str()),
            ("failed", just_old.as_str()),
            ("succeeded", recent.as_str()),
        ] {
            conn.execute(
                "INSERT INTO operations
                    (id, kind, state, actor_device_id, created_at, updated_at,
                     completed_at, cancellable, input_json)
                 VALUES (?1, 'status.test', ?2, ?3, ?4, ?4,
                         CASE WHEN ?2 IN ('failed', 'succeeded') THEN ?4 ELSE NULL END,
                         1, '{}')",
                rusqlite::params![
                    uuid::Uuid::new_v4().to_string(),
                    state_name,
                    client.device_id.to_string(),
                    timestamp,
                ],
            )
            .unwrap();
        }
    }

    let (status, body) = get_json(state, &client, "/api/v1/status").await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["operations"]["active"], 5);
    assert_eq!(body["operations"]["waiting_for_approval"], 1);
    assert_eq!(body["operations"]["failed_last_24h"], 2);
    assert_eq!(
        body["connection"]["server_observed_transport"],
        "unclassified"
    );
    assert_eq!(
        body["connection"]["access_authentication"],
        "device_signature"
    );
}
