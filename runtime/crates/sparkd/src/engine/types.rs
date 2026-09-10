use super::*;

/// Engine transition states (§31.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineState {
    Unloaded,
    Preflighting,
    Starting,
    Loading,
    HealthCheck,
    Ready,
    Draining,
    Stopping,
    Failed,
}

impl EngineState {
    pub fn as_str(self) -> &'static str {
        match self {
            EngineState::Unloaded => "unloaded",
            EngineState::Preflighting => "preflighting",
            EngineState::Starting => "starting",
            EngineState::Loading => "loading",
            EngineState::HealthCheck => "health_check",
            EngineState::Ready => "ready",
            EngineState::Draining => "draining",
            EngineState::Stopping => "stopping",
            EngineState::Failed => "failed",
        }
    }

    /// Value for the OpenAPI `InferenceState.state` enum (a strict subset).
    pub fn inference_value(self) -> &'static str {
        match self {
            EngineState::Unloaded => "unloaded",
            EngineState::Preflighting
            | EngineState::Starting
            | EngineState::Loading
            | EngineState::HealthCheck => "loading",
            EngineState::Ready => "ready",
            EngineState::Draining => "draining",
            EngineState::Stopping => "unloading",
            EngineState::Failed => "failed",
        }
    }

    pub fn accepts_requests(self) -> bool {
        matches!(self, EngineState::Ready)
    }
}

/// An active or replaced engine; launch supplies the actual bound loopback port without a bind race.
#[derive(Debug, Clone)]
pub struct EngineInstance {
    pub instance_id: Uuid,
    pub model_id: String,
    pub profile_id: String,
    pub served_name: String,
    /// Immutable snapshot root mounted read-only as `/model` (§31.3).
    pub model_snapshot: PathBuf,
    /// Loopback port actually bound; valid once launched.
    pub internal_port: u16,
    /// Per-instance random API key (defence in depth, §31.2).
    pub api_key: String,
    /// Immutable adopted Docker id; None selects the derived spark-model-<instance_id> name.
    pub external_workload_id: Option<String>,
    pub recipe: ModelRecipe,
    pub profile: Profile,
    /// Unified memory available immediately before load.
    pub memory_baseline_bytes: u64,
    /// Container cgroup cap is available memory minus the host reserve; adopted containers have no managed cap.
    pub memory_limit_bytes: Option<u64>,
    /// ADR-043: the share of unified memory vLLM must see free, derived from the reservation when the recipe has arithmetic.
    pub gpu_memory_utilisation_milli: u16,
}

pub(super) struct RollbackCandidate {
    pub(super) instance: EngineInstance,
    pub(super) relaunch: bool,
}

/// Non-secret view for handlers; never carries the API key or snapshot path.
#[derive(Debug, Clone)]
pub struct EngineView {
    pub model_id: String,
    pub profile_id: String,
    pub served_name: String,
    pub state: EngineState,
    pub active_requests: u32,
    /// Recipe-declared profile peak; this legacy field is not a live resident-memory measurement.
    pub reserved_memory_bytes: u64,
    pub(crate) recipe: ModelRecipe,
    pub last_ttft_ms: Option<f64>,
    pub last_tokens_per_second: Option<f64>,
    pub external_workload_id: Option<String>,
}

/// The exact inputs and result used by the canonical pre-launch memory gate.
#[derive(Debug, Clone, Copy)]
pub struct AdmissionEvidence {
    /// Budget the larger of declared and measured profile peaks, including engine and cache memory.
    pub required_memory_bytes: u64,
    /// Current availability or projected replacement recovery; replacement apply rechecks actual memory after stop.
    pub available_memory_bytes: u64,
    /// Memory retained for the OS and other services in addition to the model budget.
    pub system_reserve_bytes: u64,
    /// Availability minus both the system reserve and required model budget.
    pub expected_headroom_bytes: u64,
    /// The recipe arithmetic behind the budget (ADR-043); None for recipes that only declare a peak.
    pub reservation: Option<spark_models::MemoryReservation>,
    /// Largest context, in 4096-token blocks, the budget admits at the profile's request count.
    pub max_context_now: Option<u64>,
    /// Requests the budget admits at the profile's full context.
    pub max_sequences_now: Option<u32>,
    pub pressure: PressureState,
    pub decision: AdmissionDecision,
}

/// Report the container runtime actually used by this backend, including dev/mock.
#[derive(Debug, Clone)]
pub struct ContainerRuntimeReport {
    /// Backend kind: docker, mock, or none when no engine service is wired.
    pub backend_kind: &'static str,
    /// Whether the engine container runtime is reachable and healthy now.
    pub available: bool,
    /// Human-readable explanation when unavailable; never a secret.
    pub detail: Option<String>,
    /// NVIDIA OCI runtime registration required by --gpus=all; None means unreadable evidence, not absence.
    pub gpu_runtime: Option<bool>,
}

impl ContainerRuntimeReport {
    /// GPU-runtime evidence remains unknown until a probe supplies it.
    pub fn new(backend_kind: &'static str, available: bool, detail: Option<String>) -> Self {
        Self {
            backend_kind,
            available,
            detail,
            gpu_runtime: None,
        }
    }

    /// Attach GPU-runtime evidence read from the container runtime itself.
    pub fn with_gpu_runtime(mut self, gpu_runtime: Option<bool>) -> Self {
        self.gpu_runtime = gpu_runtime;
        self
    }
}

/// Result of making the recipe-authorized engine image available locally.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineImagePreparation {
    /// The exact digest was already present and passed the backend check.
    AlreadyAvailable,
    /// The backend pulled the exact digest and verified that it is present.
    Pulled,
}

/// Host actions implemented by the in-process stub and Docker/privd backends.
#[async_trait]
pub trait EngineBackend: Send + Sync {
    /// Prepare the signed recipe image separately so a first pull has its own durable stage.
    async fn prepare(
        &self,
        instance: &EngineInstance,
    ) -> Result<EngineImagePreparation, BackendError>;
    /// Start the engine; return the actually bound loopback port.
    async fn launch(&self, instance: &EngineInstance) -> Result<u16, BackendError>;

    async fn launch_accounted(
        &self,
        instance: &EngineInstance,
    ) -> Result<(u16, u64), BackendError> {
        self.launch(instance).await.map(|port| (port, 0))
    }

    /// Stop the engine, escalating when forced; success requires the process to be gone.
    async fn stop(&self, instance: &EngineInstance, force: bool) -> Result<(), BackendError>;
    /// Reconcile the previous daemon container by derived spark-model-<uuid> name; absence succeeds.
    async fn reconcile_instance(
        &self,
        instance_id: Uuid,
        external_workload_id: Option<&str>,
    ) -> Result<(), BackendError>;
    /// True while the engine process/listener is still present.
    async fn is_running(&self, instance: &EngineInstance) -> bool;
    /// Confirm process exit; an unavailable inventory must not stop a warming engine.
    async fn has_exited(&self, _instance: &EngineInstance) -> bool {
        false
    }
    /// GET /health on the loopback listener.
    async fn health(&self, instance: &EngineInstance) -> Result<bool, BackendError>;
    /// GET /v1/models on the loopback listener.
    async fn list_model_names(
        &self,
        instance: &EngineInstance,
    ) -> Result<Vec<String>, BackendError>;
    /// Tiny deterministic completion (1–4 tokens) proving the engine serves.
    async fn probe_completion(&self, instance: &EngineInstance) -> Result<(), BackendError>;
    /// Probe runtime availability synchronously through one bounded Docker socket round trip; mock needs no I/O.
    fn probe_container_runtime(&self) -> ContainerRuntimeReport;
}

#[derive(Debug)]
pub struct BackendError(pub String);

impl std::fmt::Display for BackendError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for BackendError {}

/// Stable owner-facing codes a privileged launch rejection may lead with; the operation records the code, not the prose.
pub const TYPED_LAUNCH_FAILURE_CODES: [&str; 1] = [spark_privd::backend::GPU_DRIVER_MISMATCH];

/// Record a typed code embedded in a load failure; every other failure keeps its free-text outcome as today.
pub fn launch_failure_code(outcome: &str) -> &str {
    TYPED_LAUNCH_FAILURE_CODES
        .iter()
        .copied()
        .find(|code| outcome.contains(code))
        .unwrap_or(outcome)
}

#[cfg(test)]
mod launch_failure_code_tests {
    use super::launch_failure_code;

    #[test]
    fn a_typed_code_anywhere_in_the_outcome_is_recorded_alone() {
        assert_eq!(
            launch_failure_code(
                "container launch failed: GPU_DRIVER_MISMATCH: restart the Spark [{\"docker_stderr\":\"x\"}]"
            ),
            "GPU_DRIVER_MISMATCH"
        );
    }

    #[test]
    fn other_outcomes_keep_their_text() {
        assert_eq!(
            launch_failure_code("OPERATION_CANCELLED"),
            "OPERATION_CANCELLED"
        );
        assert_eq!(
            launch_failure_code("outgoing engine memory did not recover after stop"),
            "outgoing engine memory did not recover after stop"
        );
    }
}

/// Errors surfaced to the HTTP layer.
#[derive(Debug, Clone)]
pub enum EngineError {
    /// Another engine is active or transitioning; `replace_active` required.
    Active(String),
    /// No engine is loaded.
    NotLoaded,
    /// Report the active model separately when a request names a different model.
    NotTheLoadedModel { requested: String, served: String },
    /// Drain in progress.
    Draining,
    /// Transitioning or otherwise not ready for requests.
    NotReady,
    /// Load/unload backend failure.
    Backend(String),
    /// Admission check failed.
    InsufficientMemory,
    /// Recipe/profile/model problem.
    Invalid(String),
    /// Canonical admission failure for pressure, unsafe profile or insufficient memory.
    Admission(&'static str, String),
}

impl EngineError {
    pub fn code(&self) -> &'static str {
        match self {
            EngineError::Active(_) => "ENGINE_ACTIVE",
            EngineError::NotLoaded | EngineError::NotTheLoadedModel { .. } => "MODEL_NOT_LOADED",
            EngineError::Draining => "ENGINE_DRAINING",
            EngineError::NotReady => "ENGINE_NOT_READY",
            EngineError::Backend(_) => "MODEL_LOAD_FAILED",
            EngineError::InsufficientMemory => "MODEL_INSUFFICIENT_MEMORY",
            EngineError::Invalid(_) => "MODEL_RECIPE_INVALID",
            EngineError::Admission(code, _) => code,
        }
    }

    pub fn status(&self) -> axum::http::StatusCode {
        use axum::http::StatusCode;
        match self {
            EngineError::Active(_) => StatusCode::CONFLICT,
            EngineError::NotLoaded | EngineError::NotTheLoadedModel { .. } => StatusCode::NOT_FOUND,
            EngineError::Draining | EngineError::NotReady => StatusCode::SERVICE_UNAVAILABLE,
            EngineError::Backend(_) => StatusCode::INTERNAL_SERVER_ERROR,
            EngineError::InsufficientMemory => StatusCode::CONFLICT,
            EngineError::Invalid(_) => StatusCode::UNPROCESSABLE_ENTITY,
            EngineError::Admission(_, _) => StatusCode::CONFLICT,
        }
    }

    pub fn message(&self) -> String {
        match self {
            EngineError::Active(m) => m.clone(),
            EngineError::NotLoaded => "no active engine".to_owned(),
            EngineError::NotTheLoadedModel { requested, served } => {
                format!("model {requested} is not the active engine ({served}); load it first")
            }
            EngineError::Draining => "engine is draining".to_owned(),
            EngineError::NotReady => "engine is not ready".to_owned(),
            EngineError::Backend(m) => m.clone(),
            EngineError::InsufficientMemory => "insufficient unified memory for profile".to_owned(),
            EngineError::Invalid(m) => m.clone(),
            EngineError::Admission(_, message) => message.clone(),
        }
    }

    pub fn envelope(&self) -> (axum::http::StatusCode, axum::Json<Value>) {
        (
            self.status(),
            axum::Json(json!({
                "error": { "code": self.code(), "message": self.message() }
            })),
        )
    }
}

/// An adopted container was started with the profile's declared share; that is what its evidence records.
pub fn declared_utilisation_milli(profile: &Profile) -> u16 {
    (profile.gpu_memory_utilisation * 1000.0).round() as u16
}
