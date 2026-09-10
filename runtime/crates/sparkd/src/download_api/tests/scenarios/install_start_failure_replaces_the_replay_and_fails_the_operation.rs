#[tokio::test]
async fn install_start_failure_replaces_the_replay_and_fails_the_operation() {
    let directory = tempfile::tempdir().unwrap();
    let principal = owner();
    let mut state = credential_state(directory.path(), principal.device_id);
    let recipe = spark_models::recipe::fixture::RecipeFixture::example();
    crate::store::upsert_catalogue_model(&state.database.as_ref().unwrap().lock(), &recipe)
        .unwrap();
    let credential_store = CredentialStore::new(directory.path());
    let credential_id = credential_store
        .store(
            &state.database.as_ref().unwrap().lock(),
            &recipe.source.provider,
            "preview race",
            "secret-token",
            principal.device_id,
        )
        .unwrap();
    let credential_path = credential_store
        .resolve(&state.database.as_ref().unwrap().lock(), credential_id)
        .unwrap()
        .unwrap();
    let database = state.database.as_ref().unwrap().clone();
    state = state
        .with_models(Arc::new(crate::models::ModelInventory {
            recipes: vec![recipe.clone()],
            allow_unverified_import: false,
        }))
        .with_download(crate::download::DownloadCoordinator {
            resolver: Box::new(CredentialRemovingResolver {
                calls: AtomicUsize::new(0),
                credential_path,
                database,
                credential_id,
            }),
            source: Box::new(NoFileSource),
        });
    let preview_request = InstallModelPreviewBody {
        recipe_revision: None,
        provider_credential_id: Some(credential_id.to_string()),
    };
    let preview_request_id = uuid::Uuid::new_v4();
    let preview = preview_install_model(
        State(state.clone()),
        Extension(principal.clone()),
        IdempotencyRequest {
            device_id: principal.device_id,
            method: "POST".into(),
            path: format!("/api/v1/models/{}/install/preview", recipe.id()),
            key: uuid::Uuid::new_v4(),
            body_hash: "preview".into(),
            request_id: Some(preview_request_id),
        },
        RoutePath(recipe.id().to_owned()),
        Json(preview_request),
    )
    .await
    .unwrap()
    .0;
    let digest = preview["preview_digest"].as_str().unwrap().to_owned();
    let apply_request_id = uuid::Uuid::new_v4();
    let apply_idempotency = IdempotencyRequest {
        device_id: principal.device_id,
        method: "POST".into(),
        path: format!("/api/v1/models/{}/install", recipe.id()),
        key: uuid::Uuid::new_v4(),
        body_hash: "apply".into(),
        request_id: Some(apply_request_id),
    };
    let apply = || InstallModelBody {
        recipe_revision: None,
        provider_credential_id: Some(credential_id.to_string()),
        accepted_preview_digest: Some(digest.clone()),
    };
    let first = install_model(
        State(state.clone()),
        Extension(principal.clone()),
        apply_idempotency.clone(),
        RoutePath(recipe.id().to_owned()),
        Json(apply()),
    )
    .await
    .unwrap_err();
    assert_eq!(first.0, StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(first.1["error"]["code"], "MODEL_DOWNLOAD_FAILED");

    let operation: (String, String, String) = state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .query_row(
            "SELECT id, state, error_code FROM operations WHERE kind = 'model.install'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(operation.1, "failed");
    assert_eq!(operation.2, "MODEL_DOWNLOAD_FAILED");

    let audit_rows = {
        let connection = state.database.as_ref().unwrap().lock();
        let mut statement = connection
            .prepare(
                "SELECT action, result, actor_device_id, actor_role, resource,
                        operation_id, request_id, details_json
                   FROM audit_records ORDER BY sequence",
            )
            .unwrap();
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, Option<String>>(6)?,
                    row.get::<_, String>(7)?,
                ))
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap()
    };
    let actor_id = principal.device_id.to_string();
    let model_resource = format!("model/{}", recipe.id());
    let preview_request_id = preview_request_id.to_string();
    let apply_request_id = apply_request_id.to_string();
    assert_eq!(audit_rows.len(), 5);
    assert_eq!(audit_rows[0].0, "model.install");
    assert_eq!(audit_rows[0].1, "accepted");
    assert_eq!(audit_rows[0].2.as_deref(), Some(actor_id.as_str()));
    assert_eq!(audit_rows[0].3.as_deref(), Some("owner"));
    assert_eq!(
        audit_rows[0].4.as_deref(),
        Some(format!("{model_resource}/install/preview").as_str())
    );
    assert_eq!(audit_rows[0].5, None);
    assert_eq!(audit_rows[0].6, None);
    assert_eq!(audit_rows[1].0, "model.install.preview");
    assert_eq!(audit_rows[1].1, "accepted");
    assert_eq!(audit_rows[1].2.as_deref(), Some(actor_id.as_str()));
    assert_eq!(audit_rows[1].3.as_deref(), Some("owner"));
    assert_eq!(audit_rows[1].4.as_deref(), Some(model_resource.as_str()));
    assert_eq!(audit_rows[1].5, None);
    assert_eq!(
        audit_rows[1].6.as_deref(),
        Some(preview_request_id.as_str())
    );
    assert_eq!(audit_rows[2].0, "model.install");
    assert_eq!(audit_rows[2].1, "accepted");
    assert_eq!(
        audit_rows[2].4.as_deref(),
        Some(format!("{model_resource}/install").as_str())
    );
    assert_eq!(audit_rows[2].5, None);
    assert_eq!(audit_rows[2].6, None);
    assert_eq!(audit_rows[3].0, "model.install");
    assert_eq!(audit_rows[3].1, "accepted");
    assert_eq!(audit_rows[3].5.as_deref(), Some(operation.0.as_str()));
    assert_eq!(audit_rows[3].6.as_deref(), Some(apply_request_id.as_str()));
    assert_eq!(audit_rows[4].0, "model.install");
    assert_eq!(audit_rows[4].1, "failed");
    assert_eq!(audit_rows[4].5.as_deref(), Some(operation.0.as_str()));
    assert_eq!(audit_rows[4].6, None);
    assert_eq!(audit_rows[4].7, r#"{"error_code":"MODEL_DOWNLOAD_FAILED"}"#);
    let persisted_audit = audit_rows
        .iter()
        .map(|row| row.7.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    assert!(!persisted_audit.contains(&credential_id.to_string()));
    assert!(!persisted_audit.contains("secret-token"));
    assert!(!persisted_audit.contains("provider_credential"));

    let replay = install_model(
        State(state),
        Extension(principal),
        apply_idempotency,
        RoutePath(recipe.id().to_owned()),
        Json(apply()),
    )
    .await
    .unwrap_err();
    assert_eq!(replay.0, first.0);
    assert_eq!(replay.1.0, first.1.0);
}
