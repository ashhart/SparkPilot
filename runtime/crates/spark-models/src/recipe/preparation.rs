use super::*;

impl ModelRecipe {
    pub(super) fn validate_preparation(&self) -> Result<(), RecipeError> {
        if !self.uses_qwen38_preparation() {
            return Ok(());
        }
        let options = self.engine.options.as_ref().expect("selected preparation");
        let valid = self.id() == "mia-ailab/qwen3.8-flash-next-nvfp4"
            && self.source.repository == "Mia-AiLab/Qwen3.8-Flash-Next-NVFP4"
            && self.source.revision == "925d7be6c14c6c9442ef83e8f05b5a3c39304f69"
            && self.engine.image
                == "vllm/vllm-openai@sha256:3b0e188ffceb3d07e09c3cb5215433a0020eacf02d7f882ed3a8bfd15454477e"
            && !self.security.allow_network_during_inference
            && !self.memory.has_launch_arithmetic()
            && options.mamba_cache_mode.is_none()
            && options.kv_cache_dtype == Some(KvCacheDtype::Fp8)
            && options.reasoning_parser == Some(ReasoningParser::Qwen3)
            && options.tool_call_parser == Some(ToolCallParser::Qwen3Coder)
            && !self.profiles.is_empty()
            && self.profiles.iter().all(|profile| {
                profile.max_model_length == 262_144
                    && profile.max_sequences == 4
                    && profile.max_batched_tokens == 2048
                    && (profile.gpu_memory_utilisation - 0.690).abs() < f64::EPSILON
                    && profile.expected_peak_bytes == 90 * 1024 * 1024 * 1024
            });
        if !valid {
            return Err(RecipeError::InvalidProfile(
                "Qwen preparation requires the qualified source, engine and 256K profile".into(),
            ));
        }
        Ok(())
    }
}
