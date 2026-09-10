#[tokio::test]
async fn credential_mutation_requires_fresh_presence_before_storing_the_secret() {
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
    let (authenticated, _) = credential_presence(
        &principal,
        &request.method,
        &request.path,
        &request.body_hash,
    );

    let refusal = add_credential(
        State(state.clone()),
        Extension(principal),
        Extension(authenticated),
        HeaderMap::new(),
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
    assert_eq!(refusal.1.0["error"]["code"], "USER_PRESENCE_REQUIRED");
    let listed = list_credentials(State(state), Extension(owner()))
        .await
        .unwrap();
    assert_eq!(listed.0["items"].as_array().unwrap().len(), 0);
}
