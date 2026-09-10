//! Mirror the model-recipe schema and validate security bounds such as pinned images and trustRemoteCode.

use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Error, Clone, PartialEq)]
pub enum RecipeError {
    #[error("recipe has wrong apiVersion/kind")]
    WrongKind,
    #[error("engine image must be a pinned digest, got: {0}")]
    UnpinnedImage(String),
    #[error("trust_remote_code must be false")]
    TrustRemoteCode,
    #[error("profile gpu_memory_utilisation {0} outside allowed range")]
    ProfileMemoryOutsideRange(f64),
    #[error("profile field invalid: {0}")]
    InvalidProfile(String),
    #[error("system reserve too small: {0} bytes, minimum 8 GiB")]
    InsufficientSystemReserve(u64),
    #[error("allowed media root outside /var/lib/spark-runtime/assets: {0}")]
    MediaRootOutsideAllowlist(String),
    #[error("missing signature material")]
    MissingSignature,
    #[error("memory arithmetic invalid: {0}")]
    InvalidMemoryArithmetic(String),
    #[error(
        "profile {profile} declares expectedPeakBytes {declared} but its arithmetic derives {derived}"
    )]
    PeakDisagreesWithArithmetic {
        profile: String,
        declared: u64,
        derived: u64,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Metadata {
    pub id: String,
    pub revision: String,
    pub display_name: String,
    pub publisher: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Where the publisher lives, for the app to link to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "publisherURL")]
    pub publisher_url: Option<String>,
    /// Identify the recipe author separately from the model publisher so owners can inspect both sources.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recipe_source: Option<RecipeSource>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecipeSource {
    pub name: String,
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retrieved_at: Option<String>,
}

/// Pass only enumerated engine options through the privileged allowlist; recipes carry no free-form command line.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EngineOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preparation: Option<EnginePreparation>,
    /// Select vLLM mamba-cache-mode; align keeps hybrid Mamba and prefix-cache block boundaries compatible.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mamba_cache_mode: Option<MambaCacheMode>,
    /// vLLM `--kv-cache-dtype`; `fp8` halves KV memory on GB10.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kv_cache_dtype: Option<KvCacheDtype>,
    /// Select the vLLM reasoning parser so supported reasoning output can be presented separately from the answer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_parser: Option<ReasoningParser>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_parser: Option<ToolCallParser>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EnginePreparation {
    Qwen38_78b0675,
}

/// Approved structured tool format; selecting it also enables automatic tool choice.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ToolCallParser {
    Qwen3Coder,
}

impl ToolCallParser {
    pub fn as_flag_value(self) -> &'static str {
        match self {
            Self::Qwen3Coder => "qwen3_coder",
        }
    }
}

/// Map approved reasoning formats to vLLM parser names; the privileged helper refuses other values.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReasoningParser {
    NemotronV3,
    DeepseekR1,
    Qwen3,
    Granite,
    Glm45,
    OpenaiGptoss,
}

impl ReasoningParser {
    pub fn as_flag_value(self) -> &'static str {
        match self {
            ReasoningParser::NemotronV3 => "nemotron_v3",
            ReasoningParser::DeepseekR1 => "deepseek_r1",
            ReasoningParser::Qwen3 => "qwen3",
            ReasoningParser::Granite => "granite",
            ReasoningParser::Glm45 => "glm45",
            ReasoningParser::OpenaiGptoss => "openai_gptoss",
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum MambaCacheMode {
    None,
    Align,
    All,
}

impl MambaCacheMode {
    pub fn as_flag_value(self) -> &'static str {
        match self {
            MambaCacheMode::None => "none",
            MambaCacheMode::Align => "align",
            MambaCacheMode::All => "all",
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum KvCacheDtype {
    Auto,
    Fp8,
}

impl KvCacheDtype {
    pub fn as_flag_value(self) -> &'static str {
        match self {
            KvCacheDtype::Auto => "auto",
            KvCacheDtype::Fp8 => "fp8",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Source {
    pub provider: String,
    pub repository: String,
    pub revision: String,
    pub gated: bool,
    pub trust_remote_code: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "licenceURL")]
    pub licence_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Engine {
    pub recipe: String,
    pub image: String,
    pub served_name: String,
    pub task: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokenizer_mode: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub options: Option<EngineOptions>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Capabilities {
    pub chat: bool,
    pub reasoning: bool,
    pub tool_calling: bool,
    #[serde(default)]
    pub parallel_tool_calling: bool,
    pub guided_generation: bool,
    pub vision: bool,
    pub embeddings: bool,
    pub audio_input: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Memory {
    pub minimum_system_reserve_bytes: u64,
    pub expected_weight_bytes: u64,
    pub expected_engine_overhead_bytes: u64,
    /// Attention cache cost per token across every layer; with `state_bytes_per_sequence` it derives each profile's reservation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kv_cache_bytes_per_token: Option<u64>,
    /// Recurrent (Mamba) state per scheduled sequence; zero-length models still pay this per request.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state_bytes_per_sequence: Option<u64>,
    pub measurement_confidence: String,
}

impl Memory {
    /// Both per-token fields together turn a fixed peak into arithmetic; one without the other is refused.
    pub fn has_launch_arithmetic(&self) -> bool {
        self.kv_cache_bytes_per_token.is_some() && self.state_bytes_per_sequence.is_some()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct IdlePolicy(String);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Profile {
    pub id: String,
    pub display_name: String,
    pub max_model_length: u64,
    pub max_sequences: u32,
    pub max_batched_tokens: u64,
    pub gpu_memory_utilisation: f64,
    pub expected_peak_bytes: u64,
    pub idle_policy: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Security {
    pub allow_network_during_inference: bool,
    pub allowed_media_roots: Vec<String>,
    pub allow_custom_logits_processors: bool,
    pub allow_plugins: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecipeSignature {
    #[serde(rename = "keyID")]
    pub key_id: String,
    pub algorithm: String,
    pub value: String,
}

/// Single-engine policy ceilings shared by validation, the privileged helper and capacity projections.
pub const ENGINE_MAX_MODEL_LENGTH: u64 = 1_048_576;
pub const ENGINE_MAX_SEQUENCES: u32 = 64;

/// Canonical recipe struct that mirrors the JSON Schema exactly.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelRecipe {
    pub api_version: String,
    pub kind: String,
    pub metadata: Metadata,
    pub source: Source,
    pub engine: Engine,
    pub capabilities: Capabilities,
    pub memory: Memory,
    pub profiles: Vec<Profile>,
    pub security: Security,
    pub signature: RecipeSignature,
}

impl ModelRecipe {
    pub fn uses_qwen38_preparation(&self) -> bool {
        self.engine
            .options
            .as_ref()
            .is_some_and(|options| options.preparation == Some(EnginePreparation::Qwen38_78b0675))
    }

    pub fn id(&self) -> &str {
        &self.metadata.id
    }

    /// Canonicalize all fields except signature in declaration order, matching Appendix B.7 signing bytes.
    pub fn canonical_without_signature(&self) -> Result<Vec<u8>, serde_json::Error> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Canon<'a> {
            api_version: &'a str,
            kind: &'a str,
            metadata: &'a Metadata,
            source: &'a Source,
            engine: &'a Engine,
            capabilities: &'a Capabilities,
            memory: &'a Memory,
            profiles: &'a [Profile],
            security: &'a Security,
        }
        serde_json::to_vec(&Canon {
            api_version: &self.api_version,
            kind: &self.kind,
            metadata: &self.metadata,
            source: &self.source,
            engine: &self.engine,
            capabilities: &self.capabilities,
            memory: &self.memory,
            profiles: &self.profiles,
            security: &self.security,
        })
    }

    /// Enforce every security-sensitive bound (§29.1–29.2).
    pub fn validate(&self) -> Result<(), RecipeError> {
        if self.api_version != "spark.runtime/v1" || self.kind != "ModelRecipe" {
            return Err(RecipeError::WrongKind);
        }
        let digest_ok = self
            .engine
            .image
            .rsplit_once('@')
            .is_some_and(|(repository, digest)| {
                let hex = digest.strip_prefix("sha256:").unwrap_or_default();
                !repository.is_empty()
                    && repository.len() <= 512
                    && !repository.chars().any(char::is_whitespace)
                    && hex.len() == 64
                    && hex
                        .chars()
                        .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
                    && hex.chars().any(|c| c != '0')
            });
        if !digest_ok {
            return Err(RecipeError::UnpinnedImage(self.engine.image.clone()));
        }
        if self.source.trust_remote_code {
            return Err(RecipeError::TrustRemoteCode);
        }
        if self.memory.minimum_system_reserve_bytes < 8 * 1024 * 1024 * 1024 {
            return Err(RecipeError::InsufficientSystemReserve(
                self.memory.minimum_system_reserve_bytes,
            ));
        }
        self.validate_memory_arithmetic()?;
        self.validate_preparation()?;
        for profile in &self.profiles {
            if !(256..=ENGINE_MAX_MODEL_LENGTH).contains(&profile.max_model_length)
                || !(1..=ENGINE_MAX_SEQUENCES).contains(&profile.max_sequences)
                || !(256..=1_048_576).contains(&profile.max_batched_tokens)
            {
                return Err(RecipeError::InvalidProfile(format!(
                    "{} context, sequences, or batch size exceeds engine policy",
                    profile.id
                )));
            }
            if !(0.4..=0.9).contains(&profile.gpu_memory_utilisation) {
                return Err(RecipeError::ProfileMemoryOutsideRange(
                    profile.gpu_memory_utilisation,
                ));
            }
            if profile.expected_peak_bytes == 0 {
                return Err(RecipeError::InvalidProfile(format!(
                    "{} expected_peak_bytes is zero",
                    profile.id
                )));
            }
        }
        for root in &self.security.allowed_media_roots {
            // Validate every path component because a matching asset-root prefix alone still permits traversal.
            let contained = root.starts_with("/var/lib/spark-runtime/assets/")
                && !root.split('/').any(|part| matches!(part, "." | ".."))
                && std::path::Path::new(root).components().all(|component| {
                    matches!(
                        component,
                        std::path::Component::RootDir | std::path::Component::Normal(_)
                    )
                });
            if !contained {
                return Err(RecipeError::MediaRootOutsideAllowlist(root.clone()));
            }
        }
        if self.signature.value.is_empty() {
            return Err(RecipeError::MissingSignature);
        }
        Ok(())
    }
}

/// One file of a model revision as resolved from the source manifest (§30).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RemoteFile {
    pub relative_path: String,
    pub size_bytes: u64,
    pub sha256: String,
}

/// Deterministic instance id a model/profile engages in the engine lifecycle.
pub fn engine_instance_id() -> Uuid {
    Uuid::new_v4()
}

/// Shared structurally-valid fixture for tests and verification harnesses.
#[cfg(any(test, feature = "testkit"))]
pub mod fixture {
    use super::*;

    pub struct RecipeFixture;

    impl RecipeFixture {
        pub fn example() -> ModelRecipe {
            let profile = Profile {
                id: "balanced-16k".into(),
                display_name: "Balanced 16K".into(),
                max_model_length: 16384,
                max_sequences: 4,
                max_batched_tokens: 8192,
                gpu_memory_utilisation: 0.72,
                expected_peak_bytes: 101_000_000_000,
                idle_policy: "unload_after_30m".into(),
            };
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
                    repository: "example/example-32b-instruct".into(),
                    revision: "14d7b2f3d8f8f63e000000000000000000000000".into(),
                    gated: false,
                    trust_remote_code: false,
                    licence_url: None,
                },
                engine: Engine {
                    recipe: "vllm-dgx-spark-2026-08".into(),
                    image:
                        "nvcr.io/nvidia/vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                            .into(),
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
                profiles: vec![profile],
                security: Security {
                    allow_network_during_inference: false,
                    allowed_media_roots: vec![],
                    allow_custom_logits_processors: false,
                    allow_plugins: vec![],
                },
                signature: RecipeSignature {
                    key_id: "catalogue-test".into(),
                    algorithm: "ed25519".into(),
                    value: String::new(),
                },
            }
        }
    }
}

#[cfg(test)]
#[path = "recipe/tests.rs"]
mod tests;

mod preparation;
