#[tokio::test]
async fn profile_refresh_keeps_active_engine_recipe_and_recovers_interrupted_materialization() {
    let mut peer = full_peer(false);
    let database = peer.state.database.as_ref().unwrap().clone();
    sparkd::store::mark_model_installed(&database.lock(), "example/model-32b", 4096).unwrap();
    let engine = Arc::new(EngineManager::new(
        Arc::new(InertEngineBackend(true)),
        peer.state.jobs.clone(),
        peer.state.events.clone(),
        peer.state.identity.node_id().to_string(),
        Arc::new(FakeSystemMonitor),
        database.clone(),
        peer.state.config.data_dir.join("models"),
        Duration::ZERO,
        None,
    ));
    peer.state = peer.state.with_engine(engine.clone());
    let original = peer.state.models.as_ref().unwrap().snapshot().recipes[0].clone();
    let adoption = peer
        .state
        .jobs
        .create(
            &database.lock(),
            "workload.adopt",
            peer.device_id,
            Some("example/model-32b"),
            "{}",
        )
        .unwrap();
    engine
        .spawn_adopt(
            adoption,
            &original,
            &original.profiles[0].id,
            "a".repeat(64),
            18_123,
        )
        .unwrap();
    for _ in 0..200 {
        if engine.view().is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let original_identity = sparkd::preview::active_engine(&peer.state)
        .unwrap()
        .2
        .unwrap();
    assert_eq!(
        original_identity.recipe_revision,
        original.metadata.revision
    );
    let candidate = signed_profile_update(|recipe| {
        additional_context_profile(recipe);
        recipe.profiles[1].gpu_memory_utilisation = 0.7;
        recipe.profiles[1].expected_peak_bytes = 98_000_000_000;
    });
    apply_profile_refresh(&peer, &candidate).await;
    assert_eq!(
        sparkd::preview::active_engine(&peer.state)
            .unwrap()
            .2
            .unwrap(),
        original_identity,
        "catalogue refresh must not rewrite the active engine's owned recipe"
    );
    assert_eq!(engine.view().unwrap().profile_id, original.profiles[0].id);

    // Simulate a crash after signed-file rename but before metadata commit, retaining the verified prior file as installed-recipe proof.
    database
        .lock()
        .execute(
            "UPDATE models SET recipe_revision = ?1 WHERE id = 'example/model-32b'",
            [&original.metadata.revision],
        )
        .unwrap();
    database.lock().execute(
        "UPDATE model_profiles SET gpu_memory_utilisation = ?1, expected_peak_bytes = ?2 WHERE model_id = ?3 AND profile_id = ?4",
        rusqlite::params![original.profiles[0].gpu_memory_utilisation, original.profiles[0].expected_peak_bytes, original.id(), original.profiles[0].id],
    ).unwrap();
    database.lock().execute("DELETE FROM model_profiles WHERE model_id = ?1 AND profile_id = 'context-1m'", [original.id()]).unwrap();
    let previous_path = peer.state.config.data_dir.join("catalogue.json.previous");
    let previous_bytes = std::fs::read(&previous_path).unwrap();
    let next_candidate = signed_profile_update(|recipe| {
        additional_context_profile(recipe);
        recipe.metadata.revision = "2026-09-04.2".into();
    });
    for different_bytes in [next_candidate, format!("{candidate}\n")] {
        let (_, preview) = send(
            &peer,
            Method::POST,
            "/api/v1/catalogue/refresh/preview",
            json!({"candidate_json": different_bytes}),
        )
        .await;
        assert_eq!(
            preview.unwrap()["blockers"][0]["code"],
            "CATALOGUE_RECOVERY_REQUIRED"
        );
        assert_eq!(
            std::fs::read(&previous_path).unwrap(),
            previous_bytes,
            "refusing different candidate bytes must preserve proof of the installed recipe"
        );
    }
    apply_profile_refresh(&peer, &candidate).await;
    let revision: String = database
        .lock()
        .query_row(
            "SELECT recipe_revision FROM models WHERE id = 'example/model-32b'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(revision, "2026-09-04.1");
    assert_eq!(
        sparkd::preview::active_engine(&peer.state)
            .unwrap()
            .2
            .unwrap(),
        original_identity
    );
}
