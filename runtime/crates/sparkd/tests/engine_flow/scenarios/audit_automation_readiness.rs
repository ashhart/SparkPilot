fn automation_draft(owner: uuid::Uuid) -> sparkd::automations::store::Automation {
    sparkd::automations::store::Automation {
        id: uuid::Uuid::new_v4(),
        owner_device_id: owner,
        name: "Family brief".into(),
        instructions: "Say hello.".into(),
        schedule_preset: "daily".into(),
        schedule_expression: "0 7 * * *".into(),
        timezone: "Europe/London".into(),
        model_id: "example/model-32b".into(),
        profile_id: None,
        web_access: false,
        notify: true,
        enabled: true,
        next_run_at: None,
        created_at: 0,
        updated_at: 0,
    }
}

fn sign_automation_recipe(h: &mut Harness) {
    let seed = [43; 32];
    let inventory = h.state.models.as_ref().unwrap();
    let mut recipe = RecipeFixture::example();
    spark_models::verify::testkit::sign_recipe(
        &mut recipe,
        &ed25519_dalek::SigningKey::from_bytes(&seed),
    );
    inventory.replace(Arc::new(sparkd::models::ModelInventory {
        recipes: vec![recipe],
        allow_unverified_import: false,
    }));
    let service = sparkd::catalogue_api::CatalogueRefreshService::new(
        h._dir.path().join("catalogue.json"),
        spark_models::verify::CatalogueRoot::from_seed(&seed),
        inventory.clone(),
        h.state.database.as_ref().unwrap().clone(),
    )
    .unwrap();
    h.state.catalogue_refresh = Some(Arc::new(service));
}

async fn run_live_automation(
    h: &Harness,
    automation: &sparkd::automations::store::Automation,
) -> sparkd::automations::scheduler::RunOutcome {
    use sparkd::automations::scheduler::AutomationRunner;
    tokio::time::timeout(
        Duration::from_secs(10),
        sparkd::automations::runner::LiveRunner.run(&h.state, automation),
    )
    .await
    .expect("live runner must finish")
}

#[tokio::test]
async fn audit_automation_loads_an_idle_signed_model_and_completes_in_text_tool_mode() {
    let (mut h, _, _, owner) = harness(240 << 30).await;
    sign_automation_recipe(&mut h);
    h.backend.set_text_tool_mode(true);
    assert!(h.engine.view().is_none());
    let result = run_live_automation(&h, &automation_draft(owner)).await;
    assert_eq!(result.error_code, None, "{}", result.text);
    assert!(result.text.contains("Hello"));
    assert_eq!(h.backend.launches(), 1);
    assert_eq!(h.engine.view().unwrap().profile_id, "balanced-16k");
    let conn = h.state.database.as_ref().unwrap().lock();
    let (kind, state): (String, String) = conn
        .query_row(
            "SELECT kind,state FROM operations WHERE kind='model.load'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!((kind.as_str(), state.as_str()), ("model.load", "succeeded"));
}

#[tokio::test]
async fn audit_automation_preserves_a_running_model_with_a_different_profile() {
    let (mut h, _, _, owner) = harness(240 << 30).await;
    sign_automation_recipe(&mut h);
    let mut automation = automation_draft(owner);
    assert_eq!(run_live_automation(&h, &automation).await.error_code, None);
    let port = h.engine.internal_port();
    automation.profile_id = Some("another-profile".into());
    assert_eq!(
        run_live_automation(&h, &automation)
            .await
            .error_code
            .as_deref(),
        Some("AUTOMATION_MODEL_BUSY")
    );
    assert_eq!(h.engine.internal_port(), port);
    assert_eq!(h.backend.launches(), 1);
}

#[tokio::test]
async fn audit_automation_cannot_load_after_its_owner_is_revoked() {
    let (mut h, _, _, owner) = harness(240 << 30).await;
    sign_automation_recipe(&mut h);
    let other = uuid::Uuid::new_v4();
    sparkd::store::insert_device(
        &h.state.database.as_ref().unwrap().lock(),
        &other,
        "second owner",
        "ios",
        &spki_der(&fresh_device_key()),
        "second-owner",
        "owner",
    )
    .unwrap();
    h.state
        .database
        .as_ref()
        .unwrap()
        .lock()
        .execute(
            "UPDATE devices SET revoked_at='2026-09-05T00:00:00Z' WHERE id=?1",
            [owner.to_string()],
        )
        .unwrap();
    assert_eq!(
        run_live_automation(&h, &automation_draft(owner))
            .await
            .error_code
            .as_deref(),
        Some("AUTOMATION_OWNER_UNAVAILABLE")
    );
    assert_eq!(h.backend.launches(), 0);
}

#[tokio::test]
async fn audit_automation_refuses_an_unverified_recipe_before_loading() {
    let (mut h, _, _, owner) = harness(240 << 30).await;
    sign_automation_recipe(&mut h);
    let inventory = h.state.models.as_ref().unwrap();
    let mut recipe = inventory.snapshot().recipes[0].clone();
    recipe.engine.served_name = "tampered".into();
    inventory.replace(Arc::new(sparkd::models::ModelInventory {
        recipes: vec![recipe],
        allow_unverified_import: false,
    }));
    assert_eq!(
        run_live_automation(&h, &automation_draft(owner))
            .await
            .error_code
            .as_deref(),
        Some("MODEL_RECIPE_INVALID")
    );
    assert_eq!(h.backend.launches(), 0);
}

#[tokio::test]
async fn audit_web_failure_is_a_retryable_http_error_in_the_real_router() {
    let (h, addr, key, owner) = harness(240 << 30).await;
    let settings = sparkd::automations_api::web_settings::StoredWebAccess {
        policy: "automations_and_chats".into(),
        ..Default::default()
    };
    sparkd::appliance_api::store_web_access(
        &h.state.database.as_ref().unwrap().lock(),
        &settings,
        "2026-09-05T00:00:00Z",
        owner,
    )
    .unwrap();
    let (status, body) = signed_json(
        &reqwest::Client::new(),
        addr,
        &key,
        &owner,
        "POST",
        "/api/v1/web/answer",
        Some(json!({"model":"example/model-32b","messages":[{"role":"user","content":"Hello"}]})),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::SERVICE_UNAVAILABLE, "{body}");
    assert_eq!(body["error"]["code"], "WEB_RUN_MODEL_FAILED");
    assert!(body.get("text").is_none());
}
