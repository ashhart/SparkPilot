#[tokio::test]
async fn an_unknown_category_is_refused_rather_than_ignored() {
    let (state, client, _directory) = test_state("owner");
    let (status, refusal) = send(
        state,
        signed_request(
            &client,
            Method::POST,
            "/api/v1/diagnostics/export",
            export_body(&["prompts"]),
            true,
        ),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "silently dropping an unknown category would let a client believe it was honoured"
    );
    assert_eq!(refusal["error"]["code"], "DIAGNOSTICS_CATEGORY_UNKNOWN");
}
