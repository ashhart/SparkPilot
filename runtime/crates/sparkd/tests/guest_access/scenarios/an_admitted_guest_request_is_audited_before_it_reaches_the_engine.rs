#[tokio::test]
async fn an_admitted_guest_request_is_audited_before_it_reaches_the_engine() {
    let household = household(&evening_policy());
    let (status, body) = chat(&household, "qwen3-8b").await;
    assert!(
        !error_code(&body).starts_with("GUEST_"),
        "the policy admitted this request; it failed later at {status} with {}",
        error_code(&body)
    );

    let connection = household.state.database.as_ref().expect("db").lock();
    let (actor, resource, details): (String, String, String) = connection
        .query_row(
            "SELECT COALESCE(actor_device_id,''), COALESCE(resource,''), details_json
               FROM audit_records WHERE action = 'guest.request.admitted'
              ORDER BY sequence DESC LIMIT 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("an admitted guest request is audited");
    assert_eq!(actor, household.guest.device_id.to_string());
    assert_eq!(resource, "v1/chat/completions");
    assert!(details.contains("qwen3-8b"), "the audit names the model: {details}");
}
