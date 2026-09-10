#[tokio::test]
async fn the_owner_sees_every_guest_and_revocation_takes_effect_at_once() {
    let household = household(&evening_policy());
    {
        let connection = household.state.database.as_ref().expect("db").lock();
        sparkd::guest::record_request(
            &connection,
            &household.guest.device_id,
            "2026-07-01",
            300,
            200,
            "2026-07-01T18:00:00Z",
        )
        .expect("record");
    }
    let (status, body) = send(
        &household,
        &household.owner,
        Method::GET,
        "/api/v1/shared-access",
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let guest = &body["guests"][0];
    assert_eq!(guest["display_name"], "Sam");
    assert_eq!(guest["state"], "active");
    assert_eq!(guest["today"]["total_tokens"], 500);
    assert_eq!(guest["device_id"], household.guest.device_id.to_string());
    assert_eq!(guest["allowed_models"][0], "qwen3-8b");

    set_state(&household, GrantState::Revoked);
    let (_, refused) = chat(&household, "qwen3-8b").await;
    // BH-21: a withdrawn grant holds the device at guest, so the refusal names the withdrawal itself.
    assert_eq!(
        error_code(&refused),
        "GUEST_ACCESS_REVOKED",
        "a revoked guest is refused as a revoked guest, never promoted to its stored floor"
    );
}
