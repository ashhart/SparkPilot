#[tokio::test]
async fn profile_refresh_refuses_changed_artifacts_policy_and_launches() {
    let peer = full_peer(false);
    sparkd::store::mark_model_installed(
        &peer.state.database.as_ref().unwrap().lock(),
        "example/model-32b",
        4096,
    )
    .unwrap();
    let cases: Vec<fn(&mut spark_models::ModelRecipe)> = vec![
        |recipe| recipe.source.revision = "b".repeat(40),
        |recipe| recipe.source.repository = "example/other".into(),
        |recipe| recipe.engine.image = format!("example/engine@sha256:{}", "b".repeat(64)),
        |recipe| recipe.memory.minimum_system_reserve_bytes += 1,
        |recipe| recipe.security.allow_network_during_inference = true,
        |recipe| recipe.profiles.push(recipe.profiles[1].clone()),
        |recipe| recipe.metadata.revision = RecipeFixture::example().metadata.revision,
    ];
    for change in cases {
        let candidate = signed_profile_update(|recipe| {
            additional_context_profile(recipe);
            change(recipe);
        });
        let (status, preview) = send(
            &peer,
            Method::POST,
            "/api/v1/catalogue/refresh/preview",
            json!({"candidate_json": candidate}),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{preview:?}");
        assert_eq!(
            preview.unwrap()["blockers"][0]["code"],
            "CATALOGUE_INSTALLED_MODEL_CHANGED"
        );
    }
    let database = peer.state.database.as_ref().unwrap();
    for (kind, resource, input) in [
        ("model.load", "example/model-32b", "{}"),
        (
            "workload.adopt",
            "external-workload",
            r#"{"model_id":"example/model-32b"}"#,
        ),
    ] {
        let operation_id = peer
            .state
            .jobs
            .create(
                &database.lock(),
                kind,
                peer.device_id,
                Some(resource),
                input,
            )
            .unwrap();
        let (_, preview) = send(
            &peer,
            Method::POST,
            "/api/v1/catalogue/refresh/preview",
            json!({"candidate_json": signed_profile_update(additional_context_profile)}),
        )
        .await;
        assert_eq!(
            preview.unwrap()["blockers"][0]["code"],
            "CATALOGUE_MODEL_IN_USE",
            "{kind}"
        );
        database
            .lock()
            .execute(
                "UPDATE operations SET state = 'failed' WHERE id = ?1",
                [operation_id.to_string()],
            )
            .unwrap();
    }
    database.lock().execute(
        "INSERT INTO cluster_launches (launch_id, cluster_id, recipe_id, profile_id, execution_spec_json, state, coordinator_node_id, worker_node_id, created_at, updated_at)
         VALUES (?1, ?2, 'example/model-32b', ?3, '{}', 'running', ?4, ?5, 'now', 'now')",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), uuid::Uuid::new_v4().to_string(), RecipeFixture::example().profiles[0].id, peer.state.identity.node_id().to_string(), uuid::Uuid::new_v4().to_string()],
    ).unwrap();
    let (_, preview) = send(
        &peer,
        Method::POST,
        "/api/v1/catalogue/refresh/preview",
        json!({"candidate_json": signed_profile_update(additional_context_profile)}),
    )
    .await;
    assert_eq!(
        preview.unwrap()["blockers"][0]["code"],
        "CATALOGUE_MODEL_IN_USE"
    );
}
