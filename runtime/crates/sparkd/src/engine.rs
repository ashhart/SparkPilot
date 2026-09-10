//! Own the single-engine lifecycle; host actions use EngineBackend and upstream HTTP stays on per-instance loopback ports.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use async_trait::async_trait;
use parking_lot::Mutex;
use rand::RngCore;
use rusqlite::OptionalExtension;
use serde_json::{Value, json};
use spark_models::recipe::{ModelRecipe, Profile};
use spark_telemetry::{
    AdmissionDecision, MemorySignals, PressureState, SystemMonitor,
    admission::{AdmissionRequest, check_admission},
};
use uuid::Uuid;

use crate::events::EventBus;
use crate::jobs::JobService;

/// vLLM container-internal serving port (§31.3).
pub const VLLM_CONTAINER_PORT: u16 = 8000;
/// Health poll budget at load (§31.5).
pub const HEALTH_POLL_ATTEMPTS: u32 = 30;
pub const HEALTH_POLL_INTERVAL: Duration = Duration::from_secs(1);
/// Memory-recovery tolerance against the pre-load baseline (§31.7).
pub const MEMORY_RECOVERY_TOLERANCE_BYTES: u64 = 256 * 1024 * 1024;
/// Documented internal port range (§31.1 / runtime config).
pub const INTERNAL_PORT_RANGE_START: u16 = 18100;
pub const INTERNAL_PORT_RANGE_END: u16 = 18199;

/// A successful stop with no surviving container is stopped; report reclaimable-page-cache memory recovery separately.
pub(crate) fn container_stopped(stop_succeeded: bool, still_running: bool) -> bool {
    stop_succeeded && !still_running
}

fn idle_policy_timeout(policy: &str) -> Option<Duration> {
    match policy {
        "unload_after_15m" => Some(Duration::from_secs(15 * 60)),
        "unload_after_30m" => Some(Duration::from_secs(30 * 60)),
        "unload_after_60m" => Some(Duration::from_secs(60 * 60)),
        "keep_ready" | "manual_only" => None,
        _ => None,
    }
}

/// Derive the loopback port as spark-privd does; launch reports the actual listener after any collision fallback.
pub fn derived_internal_port(instance_id: Uuid) -> u16 {
    let span = (INTERNAL_PORT_RANGE_END - INTERNAL_PORT_RANGE_START + 1) as u32;
    INTERNAL_PORT_RANGE_START + (instance_id.as_u128() as u32 % span) as u16
}

mod adoption;
mod capacity;
mod effects;
mod idle;
mod load;
mod requests;
mod startup;
mod state;
mod stop;
mod types;

use load::snapshot_path;
pub use requests::{EngineUpstream, RequestTicket};
use state::{EngineCore, drain_graced};
pub use types::*;

pub struct EngineManager {
    backend: Arc<dyn EngineBackend>,
    jobs: JobService,
    events: EventBus,
    node_id: String,
    telemetry: Arc<dyn SystemMonitor>,
    db: Arc<Mutex<rusqlite::Connection>>,
    models_root: PathBuf,
    drain_grace: Duration,
    health_check_timeout: Duration,
    memory_recovery_timeout: Duration,
    minimum_system_reserve_bytes: u64,
    guard: Mutex<Option<Arc<crate::guard::MemoryGuardService>>>,
    inner: Mutex<EngineCore>,
}

impl EngineManager {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        backend: Arc<dyn EngineBackend>,
        jobs: JobService,
        events: EventBus,
        node_id: String,
        telemetry: Arc<dyn SystemMonitor>,
        db: Arc<Mutex<rusqlite::Connection>>,
        models_root: PathBuf,
        drain_grace: Duration,
        guard: Option<Arc<crate::guard::MemoryGuardService>>,
    ) -> Self {
        Self {
            backend,
            jobs,
            events,
            node_id,
            telemetry,
            db,
            models_root,
            drain_grace,
            health_check_timeout: HEALTH_POLL_INTERVAL * HEALTH_POLL_ATTEMPTS,
            memory_recovery_timeout: Duration::ZERO,
            minimum_system_reserve_bytes: 0,
            guard: Mutex::new(guard),
            inner: Mutex::new(EngineCore::default()),
        }
    }

    /// Reserve the stricter of the appliance policy and signed recipe requirement.
    pub fn system_reserve_bytes(&self, recipe: &ModelRecipe) -> u64 {
        self.capacity().system_reserve_bytes(recipe)
    }

    /// Apply lifecycle policy; direct tests retain short deterministic defaults unless configured.
    pub fn with_model_policy(
        mut self,
        minimum_system_reserve_bytes: u64,
        health_check_timeout: Duration,
        memory_recovery_timeout: Duration,
    ) -> Self {
        self.minimum_system_reserve_bytes = minimum_system_reserve_bytes;
        self.health_check_timeout = health_check_timeout;
        self.memory_recovery_timeout = memory_recovery_timeout;
        self
    }

    /// Wire the guard after the engine, since constructing the guard requires this engine.
    pub fn set_guard(&self, guard: Arc<crate::guard::MemoryGuardService>) {
        *self.guard.lock() = Some(guard);
    }

    /// Remove surviving secret-bearing managed containers on restart; inventory reconciliation can recover credential-free adopted workloads.
    pub async fn reconcile_startup(&self) -> Result<usize, EngineError> {
        self.startup().reconcile_startup().await
    }

    /// Recover one exact adopted workload while retaining secret-bearing managed-container cleanup.
    pub async fn reconcile_startup_with_inventory(
        &self,
        inventory: &crate::models::ModelInventory,
    ) -> Result<usize, EngineError> {
        self.startup()
            .reconcile_startup_with_inventory(inventory)
            .await
    }

    /// Last admitted or finished request time; rejected requests must leave this idle-policy clock unchanged.
    pub fn last_activity(&self) -> Instant {
        self.inner.lock().last_activity
    }

    pub fn view(&self) -> Option<EngineView> {
        let core = self.inner.lock();
        let instance = core.instance.as_ref()?;
        Some(EngineView {
            model_id: instance.model_id.clone(),
            profile_id: instance.profile_id.clone(),
            served_name: instance.served_name.clone(),
            state: core.state,
            active_requests: core.active_requests,
            reserved_memory_bytes: instance.profile.expected_peak_bytes,
            recipe: instance.recipe.clone(),
            last_ttft_ms: core.last_ttft_ms,
            last_tokens_per_second: core.last_tokens_per_second,
            external_workload_id: instance.external_workload_id.clone(),
        })
    }

    /// Loopback port for verification; the proxy obtains its upstream through begin_request.
    pub fn internal_port(&self) -> Option<u16> {
        let core = self.inner.lock();
        core.instance.as_ref().map(|i| i.internal_port)
    }

    /// Truthful container-runtime availability for `/api/v1/capabilities`.
    pub fn container_runtime(&self) -> ContainerRuntimeReport {
        self.backend.probe_container_runtime()
    }

    pub fn inference_active(&self) -> Value {
        let core = self.inner.lock();
        match &core.instance {
            Some(i) => {
                let mut state = core.state.inference_value().to_owned();
                if core.state.accepts_requests() && core.active_requests == 0 {
                    state = "idle".to_owned();
                }
                json!({
                    "state": state,
                    "model_id": i.model_id,
                    "profile_id": i.profile_id,
                    "context_length": i.profile.max_model_length,
                    "active_requests": core.active_requests,
                    "queue_depth": 0,
                    "tokens_per_second": core.last_tokens_per_second,
                    "time_to_first_token_ms": core.last_ttft_ms,
                    "last_unload": null,
                })
            }
            None => json!({
                // Report the core transition state even without an instance, including failed loads.
                "state": core.state.inference_value(),
                "model_id": null,
                "profile_id": null,
                "context_length": null,
                "active_requests": 0,
                "queue_depth": 0,
                "tokens_per_second": null,
                "time_to_first_token_ms": null,
                "last_unload": core.last_unload.clone(),
            }),
        }
    }

    /// Admit a runtime-originated analysis generation using the loaded model rather than a caller-supplied name.
    pub fn begin_request(self: &Arc<Self>) -> Result<(RequestTicket, EngineUpstream), EngineError> {
        self.admit_generation(None)
    }

    /// Check readiness and model identity under the same lock as accounting; rejected requests leave counts and activity unchanged.
    pub fn admit_request(
        self: &Arc<Self>,
        requested: &str,
    ) -> Result<(RequestTicket, EngineUpstream), EngineError> {
        self.admit_generation(Some(requested))
    }

    /// Hold engine admission while committing the reservation; callbacks must acquire storage after the engine lock.
    pub(crate) fn with_pool_admission<T>(
        self: &Arc<Self>,
        admit: impl FnOnce(&EngineInstance, u32) -> Result<T, crate::pool::PoolError>,
    ) -> Result<T, crate::pool::PoolError> {
        self.requests().with_pool_admission(admit)
    }

    /// Transfer a durable reservation directly into execution; only the execution worker may release its slot.
    pub(crate) fn begin_pool_request<T>(
        self: &Arc<Self>,
        accept: impl FnOnce(&EngineInstance) -> Result<T, crate::pool::PoolError>,
    ) -> Result<(T, RequestTicket, EngineUpstream), crate::pool::PoolError> {
        self.requests().begin_pool_request(accept, |instance_id| {
            RequestTicket::new(self.clone(), true, instance_id)
        })
    }

    fn admit_generation(
        self: &Arc<Self>,
        requested: Option<&str>,
    ) -> Result<(RequestTicket, EngineUpstream), EngineError> {
        self.requests().admit_generation(requested, |instance_id| {
            RequestTicket::new(self.clone(), false, instance_id)
        })
    }

    fn end_request(&self, pool: bool, instance_id: Uuid) {
        self.requests().end_request(pool, instance_id)
    }

    fn record_metrics(&self, ttft_ms: f64, tokens_per_second: Option<f64>) {
        self.requests().record_metrics(ttft_ms, tokens_per_second)
    }

    /// Queue the handler-owned durable load operation; replacing the active model requires replace_active.
    pub fn spawn_load(
        self: &Arc<Self>,
        operation_id: Uuid,
        recipe: &ModelRecipe,
        profile_id: &str,
        replace_active: bool,
    ) -> Result<(), EngineError> {
        let (lease, instance, replaced) =
            self.loads()
                .prepare(operation_id, recipe, profile_id, replace_active)?;
        let manager = self.clone();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("engine worker runtime");
            rt.block_on(manager.loads().load_worker(
                lease,
                operation_id,
                instance,
                replaced,
                || manager.schedule_idle_watch(),
            ));
        });
        Ok(())
    }

    /// Adopt the exact running vLLM container id and port just reverified by the HTTP preview boundary.
    pub fn spawn_adopt(
        self: &Arc<Self>,
        operation_id: Uuid,
        recipe: &ModelRecipe,
        profile_id: &str,
        workload_id: String,
        host_port: u16,
    ) -> Result<(), EngineError> {
        let (lease, instance) =
            self.adoption()
                .prepare(operation_id, recipe, profile_id, workload_id, host_port)?;
        let manager = self.clone();
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("adoption worker runtime");
            runtime.block_on(
                manager
                    .adoption()
                    .adopt_worker(lease, operation_id, instance),
            );
        });
        Ok(())
    }

    /// Relinquish an adopted workload without container commands; Spark-launched instances cannot use this path.
    pub fn validate_relinquish_adopted(&self, workload_id: &str) -> Result<String, EngineError> {
        self.adoption().validate_relinquish_adopted(workload_id)
    }

    /// Reserve admission across the ownership-row transaction and in-memory transition.
    pub fn begin_relinquish_adopted(&self, workload_id: &str) -> Result<String, EngineError> {
        self.adoption().begin_relinquish_adopted(workload_id)
    }

    pub fn abort_relinquish_adopted(&self, workload_id: &str) {
        self.adoption().abort_relinquish_adopted(workload_id)
    }

    pub fn finish_relinquish_adopted(&self, workload_id: &str) -> Result<(), EngineError> {
        self.adoption().finish_relinquish_adopted(workload_id)
    }

    /// Queue an unload as a durable operation.
    pub fn spawn_unload(
        self: &Arc<Self>,
        operation_id: Uuid,
        force: bool,
    ) -> Result<(), EngineError> {
        let mut core = self.inner.lock();
        let Some(instance) = core.instance.clone() else {
            return Err(EngineError::NotLoaded);
        };
        if core.transitioning {
            return Err(EngineError::Active(
                "another engine transition is in progress".into(),
            ));
        }
        let lease = self
            .jobs
            .acquire_lease(self.db.clone(), operation_id)
            .map_err(|error| EngineError::Active(error.to_string()))?;
        core.transitioning = true;
        core.state = EngineState::Draining;
        drop(core);

        let manager = self.clone();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("engine worker runtime");
            rt.block_on(
                manager
                    .stops()
                    .unload_worker(lease, operation_id, instance, force),
            );
        });
        Ok(())
    }

    /// Reevaluate persisted idle policy and invalidate stale watchdogs by generation.
    pub fn refresh_idle_policy(self: &Arc<Self>, model_id: &str, profile_id: &str) {
        let should_refresh = {
            let mut core = self.inner.lock();
            let matches = core.instance.as_ref().is_some_and(|instance| {
                instance.model_id == model_id && instance.profile_id == profile_id
            });
            if matches {
                core.idle_generation = core.idle_generation.wrapping_add(1);
                core.last_activity = Instant::now();
            }
            matches
        };
        if should_refresh {
            self.schedule_idle_watch();
        }
    }

    fn schedule_idle_watch(self: &Arc<Self>) {
        let Some((instance_id, generation, timeout)) = self.idle().idle_watch_configuration()
        else {
            return;
        };
        let manager = self.clone();
        std::thread::spawn(move || manager.idle().idle_watch(instance_id, generation, timeout));
    }

    /// Canonical pre-launch admission checks guard pressure, stored unsafe status, measured peak and headroom.
    pub fn admission_evidence(
        &self,
        recipe: &ModelRecipe,
        profile: &Profile,
        replace_active: bool,
    ) -> Result<AdmissionEvidence, EngineError> {
        self.capacity()
            .admission_evidence(recipe, profile, replace_active)
    }

    /// Project replacement recovery from the observed pre-load baseline; apply rechecks actual memory after stop.
    pub fn replacement_available_memory_bytes(&self, current_available: u64) -> u64 {
        self.capacity()
            .replacement_available_memory_bytes(current_available)
    }

    /// Guard-driven drain: stop admitting new generations immediately.
    pub fn request_drain(&self) -> Result<(), EngineError> {
        let mut core = self.inner.lock();
        if core.instance.is_none() {
            return Err(EngineError::NotLoaded);
        }
        if core.transitioning {
            return Err(EngineError::NotReady);
        }
        if core.state.accepts_requests() {
            core.state = EngineState::Draining;
        }
        Ok(())
    }

    /// Resume only a resident guard drain; never cancel a load, unload or replacement.
    pub fn resume_guard_drain(&self) -> Result<(), EngineError> {
        let mut core = self.inner.lock();
        if core.transitioning {
            return Err(EngineError::NotReady);
        }
        if core.instance.is_some() && core.state == EngineState::Draining {
            core.state = EngineState::Ready;
        }
        Ok(())
    }

    /// Is an engine running right now (guard/ADR-008 recovery gate)?
    pub fn is_active(&self) -> bool {
        self.view().is_some()
    }

    /// Report transition ownership so previews can refuse unstable engine consequences.
    pub fn is_transitioning(&self) -> bool {
        self.inner.lock().transitioning
    }

    /// Guard stop has no durable operation: graceful for Critical, forced for Emergency.
    pub fn guard_stop(self: &Arc<Self>, force: bool) -> Result<(), EngineError> {
        let instance = {
            let mut core = self.inner.lock();
            if core.transitioning {
                return Err(EngineError::NotReady);
            }
            let instance = core.instance.clone().ok_or(EngineError::NotLoaded)?;
            core.transitioning = true;
            core.state = EngineState::Stopping;
            instance
        };
        let manager = self.clone();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("guard engine runtime");
            rt.block_on(manager.stops().guard_stop_worker(instance, force));
        });
        Ok(())
    }

    fn effects(&self) -> effects::Effects<'_> {
        effects::Effects {
            db: &self.db,
            events: &self.events,
            node_id: &self.node_id,
            guard: &self.guard,
        }
    }

    fn capacity(&self) -> capacity::Capacity<'_> {
        capacity::Capacity {
            inner: &self.inner,
            db: &self.db,
            guard: &self.guard,
            telemetry: self.telemetry.as_ref(),
            minimum_system_reserve_bytes: self.minimum_system_reserve_bytes,
            memory_recovery_timeout: self.memory_recovery_timeout,
        }
    }

    fn requests(&self) -> requests::RequestAdmission<'_> {
        requests::RequestAdmission {
            inner: &self.inner,
            db: &self.db,
        }
    }

    fn loads(&self) -> load::LoadFlow<'_> {
        load::LoadFlow {
            inner: &self.inner,
            backend: self.backend.as_ref(),
            jobs: &self.jobs,
            db: &self.db,
            models_root: &self.models_root,
            telemetry: self.telemetry.as_ref(),
            effects: self.effects(),
            capacity: self.capacity(),
            health_check_timeout: self.health_check_timeout,
            drain_grace: self.drain_grace,
        }
    }

    fn stops(&self) -> stop::StopFlow<'_> {
        stop::StopFlow {
            inner: &self.inner,
            backend: self.backend.as_ref(),
            effects: self.effects(),
            capacity: self.capacity(),
            drain_grace: self.drain_grace,
        }
    }

    fn adoption(&self) -> adoption::Adoption<'_> {
        adoption::Adoption {
            inner: &self.inner,
            backend: self.backend.as_ref(),
            jobs: &self.jobs,
            db: &self.db,
            models_root: &self.models_root,
            telemetry: self.telemetry.as_ref(),
            effects: self.effects(),
        }
    }

    fn startup(&self) -> startup::Startup<'_> {
        startup::Startup {
            inner: &self.inner,
            backend: self.backend.as_ref(),
            db: &self.db,
            node_id: &self.node_id,
            models_root: &self.models_root,
            telemetry: self.telemetry.as_ref(),
            effects: self.effects(),
        }
    }

    fn idle(&self) -> idle::IdleWatch<'_> {
        idle::IdleWatch {
            inner: &self.inner,
            db: &self.db,
            stop: self.stops(),
        }
    }
}

fn random_api_key() -> String {
    let mut bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    hex::encode(bytes)
}

#[cfg(test)]
#[path = "engine/stop_verdict_tests.rs"]
mod stop_verdict_tests;
