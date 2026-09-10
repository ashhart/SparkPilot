use super::*;

pub(super) const BASE: &str =
    "vllm/vllm-openai@sha256:3b0e188ffceb3d07e09c3cb5215433a0020eacf02d7f882ed3a8bfd15454477e";
const ASSETS: &str = "/usr/share/spark-runtime/engines/qwen38";
const MEMORY_LIMIT: u64 = 90 * 1024 * 1024 * 1024;

pub(super) fn selected(op: &PrivilegedOperation) -> bool {
    matches!(op, PrivilegedOperation::StartModel { engine_options, .. }
        if engine_options.preparation.as_deref() == Some("qwen38_78b0675"))
}

pub(super) fn validate(op: &PrivilegedOperation) -> Result<(), BackendError> {
    let PrivilegedOperation::StartModel {
        recipe_id,
        image_digest,
        model_snapshot,
        gpu_memory_utilisation_milli,
        max_model_length,
        max_sequences,
        max_batched_tokens,
        memory_limit_bytes,
        kv_cache_memory_bytes,
        engine_options,
        allow_network_during_inference,
        ..
    } = op
    else {
        return Ok(());
    };
    if !selected(op) {
        return Ok(());
    }
    let valid = recipe_id == "mia-ailab/qwen3.8-flash-next-nvfp4"
        && image_digest == BASE
        && Path::new(model_snapshot)
            .file_name()
            .and_then(|name| name.to_str())
            == Some("925d7be6c14c6c9442ef83e8f05b5a3c39304f69")
        && *gpu_memory_utilisation_milli == 690
        && *max_model_length == 262_144
        && *max_sequences == 4
        && *max_batched_tokens == 2048
        && *memory_limit_bytes == Some(MEMORY_LIMIT)
        && kv_cache_memory_bytes.is_none()
        && !allow_network_during_inference
        && engine_options.mamba_cache_mode.is_none()
        && engine_options.kv_cache_dtype.as_deref() == Some("fp8")
        && engine_options.reasoning_parser.as_deref() == Some("qwen3")
        && engine_options.tool_call_parser.as_deref() == Some("qwen3_coder");
    if !valid {
        return Err(BackendError::InvalidInput(
            "Qwen launch must match the qualified single-Spark profile".into(),
        ));
    }
    Ok(())
}

fn command(script: &str, args: &[&str]) -> Result<serde_json::Value, BackendError> {
    let output = Command::new("/usr/bin/python3")
        .arg("-B")
        .arg(format!("{ASSETS}/{script}"))
        .args(args)
        .output()?;
    if !output.status.success() {
        return Err(BackendError::Failure(
            String::from_utf8_lossy(&output.stderr)
                .chars()
                .take(2048)
                .collect(),
        ));
    }
    if output.stdout.is_empty() {
        return Ok(serde_json::Value::Null);
    }
    serde_json::from_slice(&output.stdout)
        .map_err(|_| BackendError::Failure("invalid Qwen preparation response".into()))
}

pub(super) fn prepare_image() -> Result<(), BackendError> {
    command("managed.py", &["image"])?;
    Ok(())
}

pub(super) fn configure_plan(plan: &mut ContainerPlan) {
    let index = plan
        .argv
        .iter()
        .position(|arg| arg == BASE)
        .expect("validated Qwen base");
    plan.argv.splice(
        index..index,
        [
            "--env=HF_HUB_OFFLINE=1".into(),
            "--env=OMP_NUM_THREADS=1".into(),
            "--env=OMP_WAIT_POLICY=PASSIVE".into(),
            "--env=PYTORCH_CUDA_ALLOC_CONF=garbage_collection_threshold:0.6".into(),
            "--env=MKL_NUM_THREADS=1".into(),
            "--env=OPENBLAS_NUM_THREADS=1".into(),
            "--env=TRANSFORMERS_OFFLINE=1".into(),
            "--env=VLLM_ALLOW_INSECURE_SERIALIZATION=0".into(),
            "--env=VLLM_USE_V2_MODEL_RUNNER=1".into(),
            "--env=VLLM_PLE_CPU_OFFLOAD=1".into(),
            "--env=VLLM_PLE_PACKED_TABLE_DIR=/packed".into(),
            "--env=VLLM_PLE_OFFLOAD_STEP_TIMEOUT=300".into(),
        ],
    );
    plan.argv
        .retain(|arg| arg != "--enable-prefix-caching" && arg != "--ipc=host");
    let index = plan
        .argv
        .iter()
        .position(|arg| arg == BASE)
        .expect("validated Qwen base");
    plan.argv.insert(index, "--shm-size=8g".into());
    for flag in [
        "--no-enable-prefix-caching",
        "--tensor-parallel-size",
        "1",
        "--mamba-ssm-cache-dtype",
        "bfloat16",
        "--load-format",
        "safetensors",
        "--safetensors-load-strategy",
        "lazy",
        "--enable-chunked-prefill",
        "--distributed-executor-backend",
        "mp",
        "--kv-cache-memory-bytes",
        "4294967296",
        "--limit-mm-per-prompt",
        r#"{"image":4,"video":0}"#,
        "--mm-processor-kwargs",
        r#"{"max_pixels":1048576}"#,
        "--mm-processor-cache-gb",
        "0.25",
        "--kernel-config",
        r#"{"enable_flashinfer_autotune":false}"#,
        "--compilation-config",
        r#"{"mode":0,"cudagraph_mode":"NONE"}"#,
    ] {
        plan.argv.push(flag.into());
    }
    plan.summary["engine_preparation"] = serde_json::json!("qwen38_78b0675");
    plan.summary["kv_cache_memory_bytes"] = serde_json::json!(4_u64 * 1024 * 1024 * 1024);
}

pub(super) fn prepare_launch(
    plan: &mut ContainerPlan,
    op: &PrivilegedOperation,
) -> Result<(), BackendError> {
    let PrivilegedOperation::StartModel { model_snapshot, .. } = op else {
        return Ok(());
    };
    let prepared = command("managed.py", &["table", model_snapshot])?;
    let image = prepared["image"]
        .as_str()
        .filter(|id| id.starts_with("sha256:") && id.len() == 71)
        .ok_or_else(|| BackendError::Failure("prepared Qwen image is not immutable".into()))?;
    let packed = prepared["packed"]
        .as_str()
        .filter(|path| {
            path.starts_with("/var/lib/spark-privd/qwen38/packed-")
                && !path.contains("..")
                && !path.contains(':')
        })
        .ok_or_else(|| BackendError::Failure("invalid prepared Qwen table path".into()))?;
    let index = plan
        .argv
        .iter()
        .position(|arg| arg == BASE)
        .expect("validated Qwen base");
    plan.argv[index] = image.into();
    plan.argv
        .insert(index, format!("--volume={packed}:/packed:ro"));
    Ok(())
}

pub(super) struct MemoryPolicy {
    instance: uuid::Uuid,
    armed: bool,
    pub(super) reserved_bytes: u64,
}
impl MemoryPolicy {
    pub(super) fn activate(instance: uuid::Uuid) -> Result<Self, BackendError> {
        let evidence = command("memory_policy.py", &["activate", &instance.to_string()])?;
        Ok(Self {
            instance,
            armed: true,
            reserved_bytes: evidence["host_reserved_memory_bytes"].as_u64().unwrap_or(0),
        })
    }
    pub(super) fn watch(mut self) -> Result<(), BackendError> {
        let mut child = Command::new("/usr/bin/python3")
            .arg("-B")
            .arg(format!("{ASSETS}/memory_policy.py"))
            .arg("watch")
            .arg(self.instance.to_string())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        std::thread::spawn(move || {
            let _ = child.wait();
        });
        self.armed = false;
        Ok(())
    }
}
impl Drop for MemoryPolicy {
    fn drop(&mut self) {
        if self.armed
            && let Err(error) = restore(self.instance)
        {
            tracing::error!(%error, "Qwen VM policy restoration requires reconciliation");
        }
    }
}

pub(super) fn restore(instance: uuid::Uuid) -> Result<(), BackendError> {
    // Most models never own this policy; do not require Qwen assets for their stop path.
    if Path::new("/var/lib/spark-privd/qwen38/memory.json").exists() {
        command("memory_policy.py", &["restore", &instance.to_string()])?;
    }
    Ok(())
}
