use super::*;

/// The helper never reads host memory; no supported appliance carries more than this, so a larger limit is corrupt input.
pub const MAX_MODEL_MEMORY_LIMIT_BYTES: u64 = 1 << 40;

pub(super) struct ModelPlan<'a> {
    pub(super) docker_bin: &'a String,
    pub(super) engine_cache_root: &'a Path,
    pub(super) runtime_dir: &'a Path,
    pub(super) service_uid: u32,
    pub(super) service_gid: u32,
    pub(super) model_policy: model_policy::ModelPolicy<'a>,
}

impl ModelPlan<'_> {
    /// Validate a model operation and construct its container arguments.
    pub(super) fn plan_start_model(
        &self,
        operation: &PrivilegedOperation,
    ) -> Result<ContainerPlan, BackendError> {
        let PrivilegedOperation::StartModel {
            recipe_id,
            profile_id,
            instance_id,
            image_digest,
            served_name,
            model_snapshot,
            host_port,
            api_key,
            gpu_memory_utilisation_milli,
            max_model_length,
            max_sequences,
            max_batched_tokens,
            allow_network_during_inference,
            memory_limit_bytes,
            kv_cache_memory_bytes,
            engine_options,
            ..
        } = operation
        else {
            return Err(BackendError::InvalidInput(
                "container launch plan requires start_model".into(),
            ));
        };
        qwen::validate(operation)?;
        // Reject unknown options before processing any launch fields.
        let engine_flags = engine_options.launch_flags().map_err(|reason| {
            BackendError::InvalidInput(format!("engine option refused: {reason}"))
        })?;
        if !valid_recipe_id(recipe_id) {
            return Err(BackendError::InvalidInput(format!(
                "recipe id fails allowlist: {recipe_id}"
            )));
        }
        if !valid_profile_id(profile_id) {
            return Err(BackendError::InvalidInput(format!(
                "profile id fails allowlist: {profile_id}"
            )));
        }
        if !valid_pinned_image(image_digest) {
            return Err(BackendError::InvalidInput(
                "engine image must be pinned by sha256 digest".into(),
            ));
        }
        if !valid_served_name(served_name) {
            return Err(BackendError::InvalidInput(
                "served model name fails allowlist".into(),
            ));
        }
        if !valid_api_key(api_key.expose_secret()) {
            return Err(BackendError::InvalidInput(
                "internal API key fails shape validation".into(),
            ));
        }
        let expected_port = 18_100 + ((instance_id.as_u128() as u32) % 100) as u16;
        if *host_port != expected_port {
            return Err(BackendError::InvalidInput(format!(
                "host port must be the instance-derived loopback port {expected_port}"
            )));
        }
        if !(400..=900).contains(gpu_memory_utilisation_milli) {
            return Err(BackendError::InvalidInput(
                "gpu memory utilisation must be between 0.400 and 0.900".into(),
            ));
        }
        if !(256..=1_048_576).contains(max_model_length) {
            return Err(BackendError::InvalidInput(
                "maximum model length is outside the engine policy".into(),
            ));
        }
        if !(1..=64).contains(max_sequences) {
            return Err(BackendError::InvalidInput(
                "maximum sequences is outside the engine policy".into(),
            ));
        }
        if !(256..=1_048_576).contains(max_batched_tokens) {
            return Err(BackendError::InvalidInput(
                "maximum batched tokens is outside the engine policy".into(),
            ));
        }
        if let Some(limit) = memory_limit_bytes
            && (*limit == 0 || *limit > MAX_MODEL_MEMORY_LIMIT_BYTES)
        {
            // Docker reads --memory=0 as unlimited, which would remove the host memory cap the daemon asked for.
            return Err(BackendError::InvalidInput(
                "model memory limit is outside the engine policy".into(),
            ));
        }
        if let Some(budget) = kv_cache_memory_bytes
            && (*budget == 0 || *budget > MAX_MODEL_MEMORY_LIMIT_BYTES)
        {
            // vLLM would read a zero budget as "size the cache yourself", silently reverting to the utilisation share.
            return Err(BackendError::InvalidInput(
                "engine cache budget is outside the engine policy".into(),
            ));
        }
        let (model_snapshot, snapshot_pin) =
            self.model_policy.pin_model_snapshot(model_snapshot)?;

        let container_name = format!("spark-model-{instance_id}");
        let credential_path = self
            .runtime_dir
            .join("credentials")
            .join(format!("spark-vllm-{instance_id}.env"));
        let mut argv = vec![
            self.docker_bin.clone(),
            "run".into(),
            "--detach".into(),
            "--pull=never".into(),
            format!("--name={container_name}"),
        ];
        let (vllm_host, vllm_port, network_policy) = if *allow_network_during_inference {
            argv.push("--network=host".into());
            ("127.0.0.1", *host_port, "recipe_allows_egress")
        } else {
            argv.extend([
                format!("--network={INFERENCE_ISOLATED_NETWORK}"),
                "--dns=127.0.0.1".into(),
                format!("--publish=127.0.0.1:{host_port}:{INFERENCE_CONTAINER_PORT}"),
            ]);
            ("0.0.0.0", INFERENCE_CONTAINER_PORT, "egress_isolated")
        };
        // Set equal memory and swap limits before the image argument so runaway loads cannot exhaust host memory or swap.
        if let Some(limit) = memory_limit_bytes {
            argv.push(format!("--memory={limit}"));
            argv.push(format!("--memory-swap={limit}"));
        }
        argv.extend([
            "--gpus=all".into(),
            "--ipc=host".into(),
            "--ulimit=memlock=-1".into(),
            "--ulimit=stack=67108864".into(),
            "--read-only".into(),
            "--cap-drop=ALL".into(),
            "--security-opt=no-new-privileges:true".into(),
            "--pids-limit=2048".into(),
            // Run as the model-file owner so 0600 snapshots remain readable after all capabilities are dropped.
            format!("--user={}:{}", self.service_uid, self.service_gid),
            "--tmpfs=/tmp:rw,nosuid,nodev,noexec,size=4g".into(),
            // Persist executable compile caches across unloads while retaining read-only root and noexec /tmp; see docs/development/privileged-boundaries.md.
            format!(
                "--volume={}:{ENGINE_CACHE_DIR}:rw",
                engine_cache::scoped_path(self.engine_cache_root, operation)?.display()
            ),
            format!("--env=HOME={ENGINE_CACHE_DIR}"),
            format!("--env=XDG_CACHE_HOME={ENGINE_CACHE_DIR}"),
            format!("--env=HF_HOME={ENGINE_CACHE_DIR}/huggingface"),
            format!("--env=TRITON_CACHE_DIR={ENGINE_CACHE_DIR}/triton"),
            format!("--env=TORCHINDUCTOR_CACHE_DIR={ENGINE_CACHE_DIR}/inductor"),
            format!("--env=VLLM_CACHE_ROOT={ENGINE_CACHE_DIR}/vllm"),
            "--env=VLLM_PLUGINS=".into(),
            "--env=VLLM_NO_USAGE_STATS=1".into(),
            "--env=HF_HUB_DISABLE_TELEMETRY=1".into(),
            format!("--env-file={}", credential_path.display()),
            format!("--volume={}:/model:ro", model_snapshot.display()),
            "--entrypoint=vllm".into(),
        ]);

        argv.extend([
            image_digest.clone(),
            "serve".into(),
            "/model".into(),
            "--served-model-name".into(),
            served_name.clone(),
            "--host".into(),
            vllm_host.into(),
            "--port".into(),
            vllm_port.to_string(),
            "--gpu-memory-utilization".into(),
            format!("{:.3}", f64::from(*gpu_memory_utilisation_milli) / 1000.0),
            "--max-model-len".into(),
            max_model_length.to_string(),
            "--max-num-seqs".into(),
            max_sequences.to_string(),
            "--max-num-batched-tokens".into(),
            max_batched_tokens.to_string(),
            "--enable-prefix-caching".into(),
        ]);
        // The share is what vLLM must see free at start-up; the absolute budget, when present, sizes the cache instead of it.
        if let Some(budget) = kv_cache_memory_bytes {
            argv.extend(["--kv-cache-memory-bytes".into(), budget.to_string()]);
        }
        // Translate only options already accepted by the helper allowlist.
        argv.extend(engine_flags.iter().cloned());

        let summary = serde_json::json!({
            "recipe_id": recipe_id,
            "profile_id": profile_id,
            "instance_id": instance_id,
            "container_name": container_name,
            "image_digest": image_digest,
            "entrypoint": "vllm",
            "served_name": served_name,
            "host_port": host_port,
            "loopback_only": true,
            "network_mode": if *allow_network_during_inference { "host" } else { INFERENCE_ISOLATED_NETWORK },
            "network_policy": network_policy,
            "allow_network_during_inference": allow_network_during_inference,
            "host_network": allow_network_during_inference,
            "loopback_publish": !allow_network_during_inference,
            "public_publish": false,
            "privileged": false,
            "host_pid": false,
        });

        let mut plan = ContainerPlan {
            argv,
            summary,
            credential_path,
            snapshot_pin,
        };
        if qwen::selected(operation) {
            qwen::configure_plan(&mut plan);
        }
        Ok(plan)
    }
}
