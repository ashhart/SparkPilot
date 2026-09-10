use super::*;
fn request_id(millis: i64) -> Uuid {
    let mut bytes = *Uuid::now_v7().as_bytes();
    bytes[..6].copy_from_slice(&millis.to_be_bytes()[2..]);
    Uuid::from_bytes(bytes)
}
#[test]
fn uuidv7_admission_window_has_explicit_inclusive_skew_boundaries() {
    let now = 1_000_000;
    assert!(validate_request_age(request_id(now - 120_000), now).is_ok());
    assert!(validate_request_age(request_id(now + 5_000), now).is_ok());
    assert!(validate_request_age(request_id(now - 120_001), now).is_err());
    assert!(validate_request_age(request_id(now + 5_001), now).is_err());
    assert!(validate_request_age(Uuid::new_v4(), now).is_err());
}
#[test]
fn deployment_evidence_binds_immutable_source_recipe_profile_and_instance() {
    let mut recipe = spark_models::recipe::fixture::RecipeFixture::example();
    recipe.signature.value = "verified-test-signature".into();
    let mut instance = EngineInstance {
        instance_id: Uuid::new_v4(),
        model_id: recipe.id().into(),
        profile_id: recipe.profiles[0].id.clone(),
        served_name: recipe.engine.served_name.clone(),
        model_snapshot: "/model".into(),
        internal_port: 1,
        api_key: String::new(),
        external_workload_id: None,
        profile: recipe.profiles[0].clone(),
        recipe,
        memory_baseline_bytes: 200 << 30,
        memory_limit_bytes: Some(100 << 30),
        gpu_memory_utilisation_milli: 700,
    };
    let original = deployment(&instance, "0.1.0").unwrap();
    assert_eq!(
        original.recipe_sha256,
        sha256_hex(&serde_json::to_vec(&instance.recipe).unwrap())
    );
    instance.instance_id = Uuid::new_v4();
    let restarted = deployment(&instance, "0.1.0").unwrap();
    assert_eq!(original.model_identity, restarted.model_identity);
    assert_ne!(original.deployment_id, restarted.deployment_id);
    instance.profile.max_sequences += 1;
    assert_ne!(
        restarted.deployment_id,
        deployment(&instance, "0.1.0").unwrap().deployment_id
    );
    for revision in ["main".to_string(), "a".repeat(41), "g".repeat(40)] {
        instance.recipe.source.revision = revision;
        assert!(deployment(&instance, "0.1.0").is_err());
    }
    instance.recipe.source.revision = "a".repeat(64);
    assert!(deployment(&instance, "0.1.0").is_ok());
    instance.external_workload_id = Some("b".repeat(64));
    assert!(deployment(&instance, "0.1.0").is_err());
}
