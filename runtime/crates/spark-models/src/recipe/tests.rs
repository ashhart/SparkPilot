use super::*;

fn profile(id: &str, gpu: f64, peak: u64) -> Profile {
    Profile {
        id: id.to_owned(),
        display_name: id.to_owned(),
        max_model_length: 16384,
        max_sequences: 4,
        max_batched_tokens: 8192,
        gpu_memory_utilisation: gpu,
        expected_peak_bytes: peak,
        idle_policy: "unload_after_30m".into(),
    }
}

fn recipe(image: &str) -> ModelRecipe {
    ModelRecipe {
        api_version: "spark.runtime/v1".into(),
        kind: "ModelRecipe".into(),
        metadata: Metadata {
            id: "example/model-32b".into(),
            revision: "2026-08-25.1".into(),
            display_name: "Example 32B".into(),
            publisher: "Example".into(),
            description: None,
            publisher_url: None,
            recipe_source: None,
        },
        source: Source {
            provider: "huggingface".into(),
            repository: "example/model-32b".into(),
            revision: "14d7b2f3d8f8f63e000000000000000000000000".into(),
            gated: false,
            trust_remote_code: false,
            licence_url: None,
        },
        engine: Engine {
            recipe: "vllm-dgx-spark-2026-08".into(),
            image: image.into(),
            served_name: "example-32b".into(),
            task: "generate".into(),
            tokenizer_mode: None,
            options: None,
        },
        capabilities: Capabilities {
            chat: true,
            reasoning: true,
            tool_calling: true,
            parallel_tool_calling: false,
            guided_generation: true,
            vision: false,
            embeddings: false,
            audio_input: false,
        },
        memory: Memory {
            minimum_system_reserve_bytes: 23_623_220_128,
            expected_weight_bytes: 68_719_476_736,
            expected_engine_overhead_bytes: 8_589_934_592,
            kv_cache_bytes_per_token: None,
            state_bytes_per_sequence: None,
            measurement_confidence: "curated".into(),
        },
        profiles: vec![profile("balanced-16k", 0.72, 101_000_000_000)],
        security: Security {
            allow_network_during_inference: false,
            allowed_media_roots: vec![],
            allow_custom_logits_processors: false,
            allow_plugins: vec![],
        },
        signature: RecipeSignature {
            key_id: "catalogue-2026-a".into(),
            algorithm: "ed25519".into(),
            value: "dGVzdA".into(),
        },
    }
}

#[test]
fn profile_engine_limits_are_checked_before_recipe_acceptance() {
    let mut candidate = recipe(
        "example/vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    candidate.profiles[0].max_model_length = 1_048_576;
    candidate.profiles[0].max_sequences = 64;
    candidate.profiles[0].max_batched_tokens = 1_048_576;
    assert!(candidate.validate().is_ok());
    for (length, sequences, batch) in [
        (255, 1, 256),
        (1_048_577, 1, 256),
        (256, 0, 256),
        (256, 65, 256),
        (256, 1, 255),
        (256, 1, 1_048_577),
    ] {
        candidate.profiles[0].max_model_length = length;
        candidate.profiles[0].max_sequences = sequences;
        candidate.profiles[0].max_batched_tokens = batch;
        assert!(
            matches!(candidate.validate(), Err(RecipeError::InvalidProfile(_))),
            "accepted {length}/{sequences}/{batch}"
        );
    }
}

#[test]
fn pinned_digest_recipes_validate() {
    let recipe = recipe(
        "nvcr.io/nvidia/vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    assert!(recipe.validate().is_ok());
}

#[test]
fn all_zero_image_digest_is_rejected() {
    let image = "nvcr.io/nvidia/vllm@sha256:0000000000000000000000000000000000000000000000000000000000000000";
    assert_eq!(
        recipe(image).validate(),
        Err(RecipeError::UnpinnedImage(image.into()))
    );
}

#[test]
fn unpinned_image_tag_is_rejected() {
    let recipe = recipe("nvcr.io/nvidia/vllm:latest");
    assert_eq!(
        recipe.validate(),
        Err(RecipeError::UnpinnedImage(
            "nvcr.io/nvidia/vllm:latest".into()
        ))
    );
}

#[test]
fn trust_remote_code_is_rejected() {
    let mut recipe = recipe(
        "nvcr.io/nvidia/vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    recipe.source.trust_remote_code = true;
    assert_eq!(recipe.validate(), Err(RecipeError::TrustRemoteCode));
}

#[test]
fn serde_matches_the_published_camel_case_recipe_contract() {
    let recipe = fixture::RecipeFixture::example();
    let value = serde_json::to_value(&recipe).unwrap();
    assert_eq!(value["apiVersion"], "spark.runtime/v1");
    assert!(value.get("api_version").is_none());
    assert_eq!(value["metadata"]["displayName"], "Example 32B");
    assert_eq!(value["source"]["trustRemoteCode"], false);
    assert!(value["source"].get("trust_remote_code").is_none());
    assert_eq!(value["engine"]["servedName"], "example-32b");
    assert_eq!(value["capabilities"]["toolCalling"], true);
    assert_eq!(
        value["memory"]["minimumSystemReserveBytes"],
        23_623_220_128_u64
    );
    assert_eq!(value["profiles"][0]["gpuMemoryUtilisation"], 0.72);
    assert_eq!(value["signature"]["keyID"], "catalogue-test");

    let decoded: ModelRecipe = serde_json::from_value(value).unwrap();
    assert_eq!(decoded, recipe);
    let snake = serde_json::json!({
        "api_version": "spark.runtime/v1",
        "kind": "ModelRecipe"
    });
    assert!(serde_json::from_value::<ModelRecipe>(snake).is_err());
}

#[test]
fn media_roots_must_live_under_assets() {
    let mut recipe = recipe(
        "nvcr.io/nvidia/vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    recipe.security.allowed_media_roots = vec!["/etc/passwd".into()];
    assert_eq!(
        recipe.validate(),
        Err(RecipeError::MediaRootOutsideAllowlist("/etc/passwd".into()))
    );
}

#[test]
fn media_roots_refuse_dot_and_parent_components() {
    let mut recipe = recipe(
        "nvcr.io/nvidia/vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    for path in [
        "/var/lib/spark-runtime/assets/../../etc",
        "/var/lib/spark-runtime/assets/./model",
    ] {
        recipe.security.allowed_media_roots = vec![path.into()];
        assert!(matches!(
            recipe.validate(),
            Err(RecipeError::MediaRootOutsideAllowlist(_))
        ));
    }
}

#[test]
fn canonical_bytes_are_deterministic_and_signature_free() {
    let recipe = recipe(
        "nvcr.io/nvidia/vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    let a = recipe.canonical_without_signature().unwrap();
    let b = recipe.canonical_without_signature().unwrap();
    assert_eq!(a, b);
    assert!(!String::from_utf8_lossy(&a).contains("signature"));
}
