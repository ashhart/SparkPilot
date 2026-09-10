#[tokio::test]
async fn credential_add_and_revoke_replay_the_exact_first_response() {
    let directory = tempfile::tempdir().unwrap();
    let principal = owner();
    let state = credential_state(directory.path(), principal.device_id);
    let key = uuid::Uuid::new_v4();
    let add_request = IdempotencyRequest {
        device_id: principal.device_id,
        method: "POST".into(),
        path: "/api/v1/credentials".into(),
        key,
        body_hash: "add-body".into(),
        request_id: None,
    };
    let (add_authenticated, add_headers) = credential_presence(
        &principal,
        &add_request.method,
        &add_request.path,
        &add_request.body_hash,
    );

    let first = add_credential(
        State(state.clone()),
        Extension(principal.clone()),
        Extension(add_authenticated.clone()),
        add_headers.clone(),
        add_request.clone(),
        Json(AddCredentialRequest {
            provider: "huggingface".into(),
            display_name: "models".into(),
            secret: SecretString::new("secret-token"),
        }),
    )
    .await
    .unwrap();
    let replay = add_credential(
        State(state.clone()),
        Extension(principal.clone()),
        Extension(add_authenticated),
        add_headers,
        add_request,
        Json(AddCredentialRequest {
            provider: "huggingface".into(),
            display_name: "models".into(),
            secret: SecretString::new("secret-token"),
        }),
    )
    .await
    .unwrap();
    assert_eq!(first.0, replay.0);
    assert_eq!(first.1.0, replay.1.0);
    let credential_id = uuid::Uuid::parse_str(first.1.0["id"].as_str().unwrap()).unwrap();

    let revoke_request = IdempotencyRequest {
        device_id: principal.device_id,
        method: "DELETE".into(),
        path: format!("/api/v1/credentials/{credential_id}"),
        key: uuid::Uuid::new_v4(),
        body_hash: crate::crypto::sha256_hex(&[]),
        request_id: None,
    };
    let (revoke_authenticated, revoke_headers) = credential_presence(
        &principal,
        &revoke_request.method,
        &revoke_request.path,
        &revoke_request.body_hash,
    );
    let first = revoke_credential(
        State(state.clone()),
        Extension(principal.clone()),
        Extension(revoke_authenticated.clone()),
        revoke_headers.clone(),
        revoke_request.clone(),
        RoutePath(credential_id),
    )
    .await
    .unwrap();
    let replay = revoke_credential(
        State(state),
        Extension(principal),
        Extension(revoke_authenticated),
        revoke_headers,
        revoke_request,
        RoutePath(credential_id),
    )
    .await
    .unwrap();
    assert_eq!(first.0, replay.0);
    assert_eq!(first.1.0, replay.1.0);
    assert_eq!(first.0, StatusCode::NO_CONTENT);
}
