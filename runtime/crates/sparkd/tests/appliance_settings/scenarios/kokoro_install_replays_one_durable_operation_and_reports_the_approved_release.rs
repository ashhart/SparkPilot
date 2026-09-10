#[tokio::test]
async fn kokoro_install_replays_one_durable_operation_and_reports_the_approved_release() {
    let (state, owner, observed) = test_state("owner");
    let path = "/api/v1/services/kokoro/install";
    let first = signed_request(&owner, Method::POST, path, Value::Null, true);
    let key = first.headers()["idempotency-key"].clone();
    let (status, accepted) = send(state.clone(), first).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    wait_for(&observed, "install_kokoro");
    let mut retry = signed_request(&owner, Method::POST, path, Value::Null, true);
    retry.headers_mut().insert("idempotency-key", key);
    let (_, replay) = send(state.clone(), retry).await;
    assert_eq!(replay["id"], accepted["id"]);
    assert_eq!(
        observed
            .lock()
            .unwrap()
            .iter()
            .filter(|v| v.as_str() == "install_kokoro")
            .count(),
        1
    );
    let (status, body) = send(
        state,
        signed_request(
            &owner,
            Method::GET,
            "/api/v1/services/kokoro",
            Value::Null,
            false,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["installed"], true);
    assert_eq!(body["update_available"], false);
    assert_eq!(body["available_image"], spark_privd::kokoro::IMAGE);
}
