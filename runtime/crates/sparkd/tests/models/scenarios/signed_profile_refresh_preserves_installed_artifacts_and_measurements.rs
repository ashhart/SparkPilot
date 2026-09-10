#[tokio::test]
async fn signed_profile_refresh_preserves_installed_artifacts_and_measurements() {
    let peer = full_peer(false);
    let database = peer.state.database.as_ref().unwrap();
    let original_profile = RecipeFixture::example().profiles[0].id.clone();
    {
        let connection = database.lock();
        sparkd::store::mark_model_installed(&connection, "example/model-32b", 4096).unwrap();
        connection.execute("UPDATE models SET manifest_path = 'installed-manifest', recipe_digest = 'installed-digest' WHERE id = 'example/model-32b'", []).unwrap();
        sparkd::guard::record_profile_peak(
            &connection,
            "example/model-32b",
            &original_profile,
            98_000_000_000,
            &fixture_environment(),
        )
        .unwrap();
        sparkd::guard::mark_profile_unsafe(
            &connection,
            "example/model-32b",
            &original_profile,
            "MEMORY_PRESSURE",
        )
        .unwrap();
    }
    let old_recipe = peer.state.models.as_ref().unwrap().snapshot().recipes[0].clone();
    let candidate = signed_profile_update(additional_context_profile);
    let (_, preview) = send(
        &peer,
        Method::POST,
        "/api/v1/catalogue/refresh/preview",
        json!({"candidate_json": candidate}),
    )
    .await;
    let preview = preview.unwrap();
    assert_eq!(preview["blockers"], json!([]), "{preview}");
    let (status, operation) = send(
        &peer,
        Method::POST,
        "/api/v1/catalogue/refresh",
        json!({
            "candidate_json": candidate,
            "accepted_preview_digest": preview["preview_digest"],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED, "{operation:?}");
    for _ in 0..200 {
        if peer.state.models.as_ref().unwrap().snapshot().recipes[0].profiles[0].id == "context-1m"
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let inventory = peer.state.models.as_ref().unwrap().snapshot();
    assert_eq!(inventory.recipes[0].profiles[0].max_model_length, 1_048_576);
    assert_eq!(inventory.recipes[0].source, old_recipe.source);
    assert_eq!(inventory.recipes[0].engine, old_recipe.engine);
    let connection = database.lock();
    let installed: (String, String, String, String, u64) = connection.query_row(
        "SELECT install_state, source_revision, manifest_path, recipe_digest, total_bytes FROM models WHERE id = 'example/model-32b'",
        [], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
    ).unwrap();
    assert_eq!(
        installed,
        (
            "installed".into(),
            old_recipe.source.revision,
            "installed-manifest".into(),
            "installed-digest".into(),
            4096
        )
    );
    let recipe_revision: String = connection
        .query_row(
            "SELECT recipe_revision FROM models WHERE id = 'example/model-32b'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(recipe_revision, "2026-09-04.1");
    let stored_peak: u64 = connection.query_row("SELECT measured_peak_bytes FROM model_profiles WHERE model_id = 'example/model-32b' AND profile_id = ?1", [&original_profile], |row| row.get(0)).unwrap();
    assert_eq!(stored_peak, 98_000_000_000);
    assert!(
        sparkd::guard::profile_is_unsafe(&connection, "example/model-32b", &original_profile)
            .unwrap()
    );
    let new_context: u64 = connection.query_row("SELECT context_length FROM model_profiles WHERE model_id = 'example/model-32b' AND profile_id = 'context-1m'", [], |row| row.get(0)).unwrap();
    assert_eq!(new_context, 1_048_576);
}

#[tokio::test]
async fn signed_profile_correction_updates_installed_limits_without_erasing_safety_history() {
    let peer = full_peer(false);
    let database = peer.state.database.as_ref().unwrap();
    let original = RecipeFixture::example();
    let profile_id = &original.profiles[0].id;
    {
        let conn = database.lock();
        sparkd::store::mark_model_installed(&conn, original.id(), 4096).unwrap();
        sparkd::guard::record_profile_peak(&conn, original.id(), profile_id, 98_000_000_000, &fixture_environment()).unwrap();
        sparkd::guard::mark_profile_unsafe(&conn, original.id(), profile_id, "MEMORY_PRESSURE").unwrap();
    }
    let candidate = signed_profile_update(|recipe| {
        recipe.profiles[0].gpu_memory_utilisation = 0.7;
        recipe.profiles[0].expected_peak_bytes = 98_000_000_000;
    });
    apply_profile_refresh(&peer, &candidate).await;
    let conn = database.lock();
    let row: (f64, u64, u64, bool) = conn.query_row(
        "SELECT gpu_memory_utilisation, expected_peak_bytes, measured_peak_bytes, safe FROM model_profiles WHERE model_id = ?1 AND profile_id = ?2",
        rusqlite::params![original.id(), profile_id], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
    ).unwrap();
    assert_eq!(row, (0.7, 98_000_000_000, 98_000_000_000, false));
}

#[tokio::test]
async fn signed_profile_correction_refuses_custom_settings_and_keeps_every_row() {
    let peer = full_peer(false);
    let database = peer.state.database.as_ref().unwrap();
    let original = RecipeFixture::example();
    {
        let conn = database.lock();
        sparkd::store::mark_model_installed(&conn, original.id(), 4096).unwrap();
        conn.execute("UPDATE model_profiles SET max_sequences = 17 WHERE model_id = ?1", [original.id()]).unwrap();
    }
    let candidate = signed_profile_update(|recipe| {
        recipe.profiles[0].gpu_memory_utilisation = 0.7;
        recipe.profiles[0].expected_peak_bytes = 98_000_000_000;
    });
    let (_, preview) = send(&peer, Method::POST, "/api/v1/catalogue/refresh/preview", json!({"candidate_json": candidate})).await;
    let preview = preview.unwrap();
    assert_eq!(preview["blockers"][0]["code"], "CATALOGUE_INSTALLED_MODEL_CHANGED");
    assert!(preview["blockers"][0]["owner_explanation"].as_str().unwrap().contains("custom"));
    let counts: u32 = database.lock().query_row("SELECT COUNT(*) FROM model_profiles WHERE model_id = ?1 AND max_sequences = 17", [original.id()], |row| row.get(0)).unwrap();
    assert_eq!(counts as usize, original.profiles.len());
}

#[tokio::test]
async fn added_signed_profile_cannot_replace_a_local_custom_profile() {
    let peer = full_peer(false);
    let database = peer.state.database.as_ref().unwrap();
    let original = RecipeFixture::example();
    {
        let conn = database.lock();
        sparkd::store::mark_model_installed(&conn, original.id(), 4096).unwrap();
        conn.execute("INSERT INTO model_profiles(model_id, profile_id, context_length, max_sequences, max_batched_tokens, gpu_memory_utilisation, expected_peak_bytes, safe) VALUES (?1, 'context-1m', 12345, 1, 1024, 0.5, 100000, 1)", [original.id()]).unwrap();
    }
    let (_, preview) = send(&peer, Method::POST, "/api/v1/catalogue/refresh/preview", json!({"candidate_json": signed_profile_update(additional_context_profile)})).await;
    assert_eq!(preview.unwrap()["blockers"][0]["code"], "CATALOGUE_INSTALLED_MODEL_CHANGED");
    let context: u64 = database.lock().query_row("SELECT context_length FROM model_profiles WHERE model_id = ?1 AND profile_id = 'context-1m'", [original.id()], |row| row.get(0)).unwrap();
    assert_eq!(context, 12345);
}

#[tokio::test]
async fn legacy_revision_marker_can_advance_when_limits_match_the_current_signed_recipe() {
    let peer = full_peer(false);
    let database = peer.state.database.as_ref().unwrap();
    let original = RecipeFixture::example();
    {
        let conn = database.lock();
        sparkd::store::mark_model_installed(&conn, original.id(), 4096).unwrap();
        conn.execute("UPDATE models SET recipe_revision = 'legacy-installed-revision' WHERE id = ?1", [original.id()]).unwrap();
    }
    let candidate = signed_profile_update(|recipe| {
        recipe.profiles[0].gpu_memory_utilisation = 0.7;
        recipe.profiles[0].expected_peak_bytes = 98_000_000_000;
    });
    apply_profile_refresh(&peer, &candidate).await;
    let revision: String = database.lock().query_row("SELECT recipe_revision FROM models WHERE id = ?1", [original.id()], |row| row.get(0)).unwrap();
    assert_eq!(revision, "2026-09-04.1");
}

#[tokio::test]
async fn signed_architecture_refresh_retires_presets_without_deleting_their_history() {
    let peer = full_peer(false);
    let database = peer.state.database.as_ref().unwrap();
    let original = RecipeFixture::example();
    sparkd::store::mark_model_installed(&database.lock(), original.id(), 4096).unwrap();
    database.lock().execute(
        "INSERT INTO inference_instances (id, model_id, profile_id, node_id, state) VALUES ('retired-history', ?1, ?2, ?3, 'stopped')",
        rusqlite::params![original.id(), original.profiles[0].id, peer.state.identity.node_id().to_string()],
    ).unwrap();
    let candidate = signed_profile_update(|recipe| {
        additional_context_profile(recipe);
        recipe.profiles.retain(|profile| profile.id == "context-1m");
        recipe.memory.kv_cache_bytes_per_token = Some(4704);
        recipe.memory.state_bytes_per_sequence = Some(25165824);
        for profile in &mut recipe.profiles {
            profile.expected_peak_bytes = recipe.memory.expected_weight_bytes
                + recipe.memory.expected_engine_overhead_bytes
                + 4704 * profile.max_model_length * u64::from(profile.max_sequences)
                + 25165824 * u64::from(profile.max_sequences);
        }
    });
    apply_profile_refresh(&peer, &candidate).await;
    let (_, detail) = get(&peer, "/api/v1/models/example%2Fmodel-32b").await;
    let profiles = detail.unwrap()["profiles"].as_array().unwrap().clone();
    assert_eq!(profiles.len(), 1, "retired presets must not be offered for launch");
    assert_eq!(profiles[0]["id"], "context-1m");
    let conn = database.lock();
    let history: String = conn.query_row("SELECT profile_id FROM inference_instances WHERE id = 'retired-history'", [], |row| row.get(0)).unwrap();
    assert_eq!(history, original.profiles[0].id);
    let count: usize = conn.query_row("SELECT COUNT(*) FROM model_profiles WHERE model_id = ?1", [original.id()], |row| row.get(0)).unwrap();
    assert_eq!(count, original.profiles.len() + 1, "retired preset rows remain for historical instance foreign keys");
    let revision: String = conn.query_row("SELECT recipe_revision FROM models WHERE id = ?1", [original.id()], |row| row.get(0)).unwrap();
    assert_eq!(revision, "2026-09-04.1");
}
