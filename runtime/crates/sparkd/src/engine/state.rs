use super::*;

/// What the last stop found about unified memory, kept while nothing is loaded so the owner can see an unreclaimed engine.
#[derive(Debug, Clone, serde::Serialize)]
pub struct UnloadEvidence {
    pub model_id: String,
    pub memory_recovered: bool,
    pub baseline_bytes: u64,
    pub available_bytes: u64,
    pub finished_at: String,
}

pub(super) struct EngineCore {
    /// Set only once the engine reaches Ready; drives replace/unload.
    pub(super) instance: Option<EngineInstance>,
    /// Evidence from the most recent stop; cleared when a model reaches Ready.
    pub(super) last_unload: Option<UnloadEvidence>,
    pub(super) state: EngineState,
    pub(super) transitioning: bool,
    pub(super) active_requests: u32,
    /// Pool executions are also represented by durable capacity charges.
    pub(super) pool_active_requests: u32,
    pub(super) last_activity: Instant,
    pub(super) idle_generation: u64,
    pub(super) last_ttft_ms: Option<f64>,
    pub(super) last_tokens_per_second: Option<f64>,
}

impl Default for EngineCore {
    fn default() -> Self {
        Self {
            instance: None,
            last_unload: None,
            state: EngineState::Unloaded,
            transitioning: false,
            active_requests: 0,
            pool_active_requests: 0,
            last_activity: Instant::now(),
            idle_generation: 0,
            last_ttft_ms: None,
            last_tokens_per_second: None,
        }
    }
}

pub(super) async fn drain_graced(inner: &Mutex<EngineCore>, drain_grace: Duration) {
    // Monotonic: an NTP step during the grace window must not distort it.
    let deadline = tokio::time::Instant::now() + drain_grace;
    while tokio::time::Instant::now() < deadline {
        if inner.lock().active_requests == 0 {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}
