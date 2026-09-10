#[tokio::test]
async fn ordinary_role_cannot_add_a_provider_credential() {
    let directory = tempfile::tempdir().unwrap();
    let owner = owner();
    let state = credential_state(directory.path(), owner.device_id);
    let user = Principal {
        device_id: uuid::Uuid::new_v4(),
        role: "user".into(),
        access_authentication: crate::auth::AccessAuthentication::DeviceSignature,
        user_presence: None,
    };
    let request = IdempotencyRequest {
        device_id: user.device_id,
        method: "POST".into(),
        path: "/api/v1/credentials".into(),
        key: uuid::Uuid::new_v4(),
        body_hash: "add-body".into(),
        request_id: None,
    };
    let authenticated = AuthenticatedRequest {
        node_id: uuid::Uuid::from_u128(2),
        method: request.method.clone(),
        path_and_query: request.path.clone(),
        timestamp: time::OffsetDateTime::now_utc()
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap(),
        nonce: "ordinary-role-nonce".into(),
        content_sha256: request.body_hash.clone(),
        device_id: user.device_id,
    };

    let refusal = add_credential(
        State(state.clone()),
        Extension(user),
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
    let listed = list_credentials(State(state), Extension(owner))
        .await
        .unwrap();
    assert!(listed.0["items"].as_array().unwrap().is_empty());
}
