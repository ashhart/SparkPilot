#[tokio::test]
async fn credential_list_is_role_gated_and_contains_no_secret_fields() {
    let directory = tempfile::tempdir().unwrap();
    let principal = owner();
    let state = credential_state(directory.path(), principal.device_id);
    CredentialStore::new(directory.path())
        .store(
            &state.database.as_ref().unwrap().lock(),
            "huggingface",
            "private models",
            "hf_secret_never_returned",
            principal.device_id,
        )
        .unwrap();

    let response = list_credentials(State(state.clone()), Extension(principal))
        .await
        .unwrap();
    let encoded = response.0.to_string();
    assert!(encoded.contains("private models"));
    assert!(!encoded.contains("hf_secret_never_returned"));
    assert!(!encoded.contains("secret_reference"));

    let user = Principal {
        device_id: uuid::Uuid::new_v4(),
        role: "user".into(),
        access_authentication: crate::auth::AccessAuthentication::DeviceSignature,
        user_presence: None,
    };
    let refusal = list_credentials(State(state), Extension(user))
        .await
        .unwrap_err();
    assert_eq!(refusal.0, StatusCode::FORBIDDEN);
}
