#[tokio::test]
async fn a_guest_reads_its_own_usage_and_no_one_elses() {
    let household = household(&evening_policy());
    {
        let connection = household.state.database.as_ref().expect("db").lock();
        sparkd::guest::record_request(
            &connection,
            &household.guest.device_id,
            "2026-07-01",
            120,
            80,
            "2026-07-01T18:00:00Z",
        )
        .expect("record");
    }
    let (status, body) = send(
        &household,
        &household.guest,
        Method::GET,
        "/api/v1/shared-access/self",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["display_name"], "Sam");
    assert_eq!(body["state"], "active");
    assert_eq!(body["daily_token_budget"], 10_000);
    assert_eq!(body["today"]["total_tokens"], 200);
    assert_eq!(body["today"]["requests"], 1);
    assert_eq!(body["allowed_models"][0], "qwen3-8b");
    assert!(body.get("guests").is_none(), "a guest never sees other guests");
    assert!(
        body.as_object().expect("object").keys().all(|key| key != "device_id"),
        "a guest's own record does not hand it device identifiers"
    );
}
