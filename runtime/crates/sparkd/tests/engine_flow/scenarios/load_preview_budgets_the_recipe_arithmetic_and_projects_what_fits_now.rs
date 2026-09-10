/// The fixture with Nemotron's per-token figures: 262,144 tokens for 16 requests, and a 1M-token sibling profile.
fn recipe_with_launch_arithmetic() -> ModelRecipe {
    let mut recipe = RecipeFixture::example();
    recipe.memory.expected_weight_bytes = 24_000_000_000;
    recipe.memory.expected_engine_overhead_bytes = 8_589_934_592;
    recipe.memory.kv_cache_bytes_per_token = Some(3072);
    recipe.memory.state_bytes_per_sequence = Some(25_165_824);
    recipe.profiles[0].max_model_length = 262_144;
    recipe.profiles[0].max_sequences = 16;
    recipe.profiles[0].expected_peak_bytes = 45_877_489_664;
    let mut long = recipe.profiles[0].clone();
    long.id = "long-1m".into();
    long.max_model_length = 1_048_576;
    long.max_sequences = 4;
    long.expected_peak_bytes = 45_575_499_776;
    recipe.profiles.push(long);
    recipe.signature.value = "dGVzdA".into();
    recipe.validate().expect("the arithmetic recipe validates");
    recipe
}

#[tokio::test]
async fn load_preview_budgets_the_recipe_arithmetic_and_projects_what_fits_now() {
    let recipe = recipe_with_launch_arithmetic();
    let (h, addr, key, device_id) = harness_with_recipe(123_540_000_000, recipe.clone()).await;
    let client = reqwest::Client::new();
    let (status, preview) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load/preview",
        Some(json!({"model_id": "example/model-32b", "profile_id": "balanced-16k"})),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{preview}");
    let evidence = &preview["evidence"];
    // Weights 24 GB + 12,884,901,888 cache + 402,653,184 state + 8,589,934,592 overhead, not a 70 percent grab.
    assert_eq!(evidence["required_memory_bytes"], 45_877_489_664_u64);
    assert_eq!(evidence["weight_bytes"], 24_000_000_000_u64);
    assert_eq!(evidence["kv_cache_bytes"], 12_884_901_888_u64);
    assert_eq!(evidence["state_bytes"], 402_653_184_u64);
    assert_eq!(evidence["engine_overhead_bytes"], 8_589_934_592_u64);
    assert_eq!(evidence["system_reserve_bytes"], 23_623_220_128_u64);
    assert_eq!(evidence["expected_memory_headroom_bytes"], 54_039_290_208_u64);
    assert_eq!(evidence["memory_admission"], "allow");
    // 99,916,779,872 budget minus weights, overhead and state admits 1,361,594 tokens per request, capped at the 1M profile.
    assert_eq!(evidence["max_context_now"], 1_048_576_u64);
    assert_eq!(evidence["max_sequences_now"], 64_u64);

    // A measured peak raises the budget and never lowers it.
    let environment = sparkd::guard::recipe_environment(&recipe);
    let db = h.state.database.as_ref().unwrap();
    sparkd::guard::record_profile_peak(&db.lock(), recipe.id(), "balanced-16k", 40_000_000_000, &environment).unwrap();
    let admission = h.engine.admission_evidence(&recipe, &recipe.profiles[0], false).unwrap();
    assert_eq!(admission.required_memory_bytes, 45_877_489_664);
    sparkd::guard::record_profile_peak(&db.lock(), recipe.id(), "balanced-16k", 50_000_000_000, &environment).unwrap();
    let admission = h.engine.admission_evidence(&recipe, &recipe.profiles[0], false).unwrap();
    assert_eq!(admission.required_memory_bytes, 50_000_000_000);
    assert_eq!(admission.reservation.map(|r| r.total_bytes()), Some(45_877_489_664));

    // With 60 GB free the same profile no longer fits, and the projection says what would: 65,536 tokens or 4 requests.
    h.available.store(60_000_000_000, Ordering::SeqCst);
    let (status, preview) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load/preview",
        Some(json!({"model_id": "example/model-32b", "profile_id": "balanced-16k"})),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{preview}");
    assert_eq!(preview["evidence"]["memory_admission"], "deny_insufficient_memory");
    assert_eq!(preview["evidence"]["max_context_now"], 65_536_u64);
    assert_eq!(preview["evidence"]["max_sequences_now"], 4_u64);
}

#[tokio::test]
async fn load_preview_for_a_recipe_without_arithmetic_omits_the_breakdown() {
    let (_h, addr, key, device_id) = harness(126_950_000_000).await;
    let client = reqwest::Client::new();
    let (status, preview) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "POST",
        "/api/v1/inference/load/preview",
        Some(json!({"model_id": "example/model-32b", "profile_id": "balanced-16k"})),
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{preview}");
    assert_eq!(preview["evidence"]["required_memory_bytes"], 101_000_000_000_u64);
    for field in ["weight_bytes", "kv_cache_bytes", "state_bytes", "engine_overhead_bytes", "max_context_now", "max_sequences_now"] {
        assert!(preview["evidence"].get(field).is_none(), "{field} must stay absent without arithmetic");
    }
}
