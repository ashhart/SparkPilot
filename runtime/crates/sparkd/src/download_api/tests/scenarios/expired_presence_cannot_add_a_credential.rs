#[tokio::test]
async fn expired_presence_cannot_add_a_credential() {
    let directory = tempfile::tempdir().unwrap();
    let principal = owner();
    let state = credential_state(directory.path(), principal.device_id);
    let request = IdempotencyRequest {
        device_id: principal.device_id,
        method: "POST".into(),
        path: "/api/v1/credentials".into(),
        key: uuid::Uuid::new_v4(),
        body_hash: "add-body".into(),
        request_id: None,
    };
    let (authenticated, headers) = credential_presence_expiring(
        &principal,
        &request.method,
        &request.path,
        &request.body_hash,
        -1,
    );

    let refusal = add_credential(
        State(state),
        Extension(principal),
        Extension(authenticated),
        headers,
        request,
        Json(AddCredentialRequest {
            provider: "huggingface".into(),
            display_name: "private models".into(),
            secret: SecretString::new("must-not-be-stored"),
        }),
    )
    .await
    .unwrap_err();

    assert_eq!(refusal.0, StatusCode::FORBIDDEN);
    assert_eq!(refusal.1.0["error"]["code"], "USER_PRESENCE_EXPIRED");
}
