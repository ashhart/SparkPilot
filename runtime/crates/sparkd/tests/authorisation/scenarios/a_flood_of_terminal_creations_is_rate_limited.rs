/// Abuse budgets are per principal and per operation class (§16.4).
#[tokio::test]
async fn a_flood_of_terminal_creations_is_rate_limited() {
    let harness = harness();
    let key = fresh_key();
    let device_id = seed_device(&harness.state, &key, "owner");
    let project = uuid::Uuid::new_v4();

    // Drive terminal creation beyond its tight budget; earlier handler statuses do not determine the rate-limit assertion.
    let mut limited = false;
    for _ in 0..40 {
        let (status, _) = send(
            &harness.state,
            signed(
                &key,
                &device_id,
                Method::POST,
                &format!("/api/v1/projects/{project}/terminals"),
                br#"{"shell":"login"}"#,
                &fresh_nonce(),
            ),
        )
        .await;
        if status == StatusCode::TOO_MANY_REQUESTS {
            limited = true;
            break;
        }
    }
    assert!(limited, "the terminal class must engage its budget");

    // A different class is unaffected by the exhausted one.
    let (status, _) = send(
        &harness.state,
        signed(
            &key,
            &device_id,
            Method::GET,
            "/api/v1/identity",
            &[],
            &fresh_nonce(),
        ),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "exhausting one class must not close another"
    );
}
