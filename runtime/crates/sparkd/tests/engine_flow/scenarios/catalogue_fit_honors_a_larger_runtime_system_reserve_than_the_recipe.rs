#[tokio::test]
async fn catalogue_fit_honors_a_larger_runtime_system_reserve_than_the_recipe() {
    let (h, _, _, _) = harness(130_000_000_000).await;
    let manager = Arc::new(
        EngineManager::new(
            h.backend.clone(),
            h.state.jobs.clone(),
            h.state.events.clone(),
            h.state.identity.node_id().to_string(),
            h.state.telemetry.clone(),
            h.state.database.as_ref().unwrap().clone(),
            h._dir.path().join("models"),
            Duration::ZERO,
            None,
        )
        .with_model_policy(40_000_000_000, Duration::from_secs(30), Duration::ZERO),
    );
    let state = h.state.clone().with_engine(manager.clone());
    let recipe = RecipeFixture::example();
    let evidence = manager
        .admission_evidence(&recipe, &recipe.profiles[0], false)
        .unwrap();
    assert_eq!(evidence.system_reserve_bytes, 40_000_000_000);
    assert!(!evidence.decision.is_allowed());
    let axum::Json(response) = sparkd::models::list_models_impl(&state).await.unwrap();
    let model = response["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|model| model["id"] == recipe.id())
        .unwrap();
    assert_eq!(
        model["fit"], "smaller_profile_required",
        "fit must preserve the same appliance reserve as the load gate"
    );
}
