fn qwen_operation() -> PrivilegedOperation {
    let mut operation = start_operation(Uuid::new_v4());
    if let PrivilegedOperation::StartModel {
        recipe_id, image_digest, model_snapshot, gpu_memory_utilisation_milli,
        max_model_length, max_sequences, max_batched_tokens, memory_limit_bytes, engine_options, ..
    } = &mut operation {
        *recipe_id = "mia-ailab/qwen3.8-flash-next-nvfp4".into();
        *image_digest = "vllm/vllm-openai@sha256:3b0e188ffceb3d07e09c3cb5215433a0020eacf02d7f882ed3a8bfd15454477e".into();
        *model_snapshot = "/var/lib/spark-runtime/models/snapshots/mia-ailab/qwen3.8-flash-next-nvfp4/925d7be6c14c6c9442ef83e8f05b5a3c39304f69".into();
        *gpu_memory_utilisation_milli = 690;
        *max_model_length = 262_144;
        *max_sequences = 4;
        *max_batched_tokens = 2048;
        *memory_limit_bytes = Some(90 * 1024 * 1024 * 1024);
        engine_options.preparation = Some("qwen38_78b0675".into());
        engine_options.kv_cache_dtype = Some("fp8".into());
        engine_options.reasoning_parser = Some("qwen3".into());
        engine_options.tool_call_parser = Some("qwen3_coder".into());
    }
    operation
}

#[test]
fn qwen_uses_qualified_flags_and_refuses_profile_or_source_drift() {
    let backend = DockerBackend::new("docker", true);
    let plan = backend.plan_start_model(&qwen_operation()).unwrap();
    for flag in ["--env=VLLM_PLE_CPU_OFFLOAD=1", "--env=HF_HUB_OFFLINE=1",
                 "--shm-size=8g", "--enable-auto-tool-choice", "--enable-chunked-prefill",
                 "--env=VLLM_PLUGINS=", "--env=VLLM_NO_USAGE_STATS=1",
                 "--env=VLLM_ALLOW_INSECURE_SERIALIZATION=0", "--env=OMP_NUM_THREADS=1",
                 "--env=OMP_WAIT_POLICY=PASSIVE",
                 "--env=PYTORCH_CUDA_ALLOC_CONF=garbage_collection_threshold:0.6"] {
        assert!(plan.argv.contains(&flag.to_owned()), "missing {flag}");
    }
    assert!(plan.argv.windows(2).any(|pair| pair == ["--kernel-config", r#"{"enable_flashinfer_autotune":false}"#]));
    assert!(plan.argv.windows(2).any(|pair| pair == ["--compilation-config", r#"{"mode":0,"cudagraph_mode":"NONE"}"#]));
    assert!(!plan.argv.contains(&"--enable-prefix-caching".into()));
    assert!(plan.argv.contains(&"--no-enable-prefix-caching".into()));
    assert!(!plan.argv.contains(&"--ipc=host".into()));
    assert!(!plan.argv.contains(&"--speculative-config".into()));
    assert!(plan.argv.windows(2).any(|pair| pair == ["--kv-cache-memory-bytes", "4294967296"]));
    assert!(plan.argv.windows(2).any(|pair| pair == ["--limit-mm-per-prompt", r#"{"image":4,"video":0}"#]));
    assert!(plan.argv.windows(2).any(|pair| pair == ["--mm-processor-kwargs", r#"{"max_pixels":1048576}"#]));
    assert!(plan.argv.windows(2).any(|pair| pair == ["--mm-processor-cache-gb", "0.25"]));
    assert!(plan.argv.windows(2).any(|pair| pair == ["--mamba-ssm-cache-dtype", "bfloat16"]));
    for field in ["image_digest", "gpu_memory_utilisation_milli", "max_sequences", "memory_limit_bytes", "model_snapshot", "preparation"] {
        let mut value = serde_json::to_value(qwen_operation()).unwrap();
        match field {
            "image_digest" => value[field] = serde_json::json!(format!("example/engine@sha256:{}", "a".repeat(64))),
            "gpu_memory_utilisation_milli" => value[field] = serde_json::json!(704),
            "max_sequences" => value[field] = serde_json::json!(16),
            "memory_limit_bytes" => value[field] = serde_json::Value::Null,
            "model_snapshot" => value[field] = serde_json::json!("/var/lib/spark-runtime/models/snapshots/another/revision"),
            _ => value["engine_options"]["preparation"] = serde_json::json!("arbitrary-script"),
        }
        let operation = serde_json::from_value(value).unwrap();
        assert!(backend.plan_start_model(&operation).is_err(), "accepted modified {field}");
    }
}

#[test]
fn engine_caches_do_not_cross_models_or_image_revisions() {
    let backend = DockerBackend::new("docker", true);
    let cache = |op: &PrivilegedOperation| {
        backend.plan_start_model(op).unwrap().argv.into_iter()
            .find(|arg| arg.starts_with("--volume=") && arg.ends_with(":/engine-cache:rw"))
            .expect("persistent engine cache")
    };
    let normal = start_operation(Uuid::new_v4());
    let qwen = qwen_operation();
    assert_ne!(cache(&normal), cache(&qwen), "engines can poison each other's executable cache");
    let mut revised = normal.clone();
    if let PrivilegedOperation::StartModel { image_digest, .. } = &mut revised {
        *image_digest = format!("vllm/vllm-openai@sha256:{}", "b".repeat(64));
    }
    assert_ne!(cache(&normal), cache(&revised));
    let mut different_model = normal.clone();
    if let PrivilegedOperation::StartModel { recipe_id, .. } = &mut different_model {
        *recipe_id = "example/another-model".into();
    }
    assert_ne!(cache(&normal), cache(&different_model));
    let mut different_snapshot = normal.clone();
    if let PrivilegedOperation::StartModel { model_snapshot, .. } = &mut different_snapshot {
        *model_snapshot = "/var/lib/spark-runtime/models/snapshots/example/model-32b/new-revision".into();
    }
    assert_ne!(cache(&normal), cache(&different_snapshot));
    assert_eq!(cache(&normal), cache(&normal));
}
