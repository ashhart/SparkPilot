//! Drive pressure transitions through EngineControl for draining, graceful unload and emergency stop.

use std::sync::Arc;

use std::sync::atomic::{AtomicBool, Ordering};

use std::time::Duration;

use parking_lot::Mutex;

use rusqlite::Connection;

use serde_json::{Value, json};

use spark_telemetry::MemoryPolicy;

use spark_telemetry::MemorySource;

use spark_telemetry::ObservationContext;

use spark_telemetry::PressureState;

use spark_telemetry::PressureStateMachine;

use spark_telemetry::PressureTransition;

use spark_telemetry::SystemMonitor;

use spark_telemetry::classify::MemoryAction;

use spark_telemetry::thermal::{
    ThermalPolicy, ThermalState, ThermalStateMachine, ThermalTransition,
};

use crate::events::EventBus;

/// Track the exact loaded profile so pressure failures can mark it unsafe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActiveProfile {
    pub model_id: String,
    pub profile_id: String,
}

/// Require idempotent engine actions because pressure samples may repeat them.
pub trait EngineControl: Send + Sync {
    /// Stop admitting inference and drain queued work (Draining).
    fn drain(&self) -> Result<(), String>;
    /// Resume a guard-owned drain after both pressure policies recover.
    fn resume(&self) -> Result<(), String> {
        Ok(())
    }
    /// Gracefully stop at Critical pressure and verify memory recovery.
    fn graceful_unload(&self) -> Result<(), String>;
    /// Immediate container stop (Emergency). Never waits for drain.
    fn emergency_stop(&self) -> Result<(), String>;

    /// Whether an engine is mid-load, when memory falls fast by design.
    fn engine_loading(&self) -> bool {
        false
    }
    /// Whether an engine is running right now.
    fn engine_active(&self) -> bool;
}

/// Apply graceful Critical and immediate Emergency stops through the engine lifecycle, verifying inactivity before memory recovery.
#[derive(Clone)]
pub struct GuardEngine {
    manager: std::sync::Arc<crate::engine::EngineManager>,
}

impl GuardEngine {
    pub fn new(manager: std::sync::Arc<crate::engine::EngineManager>) -> Self {
        Self { manager }
    }
}

impl EngineControl for GuardEngine {
    fn resume(&self) -> Result<(), String> {
        self.manager
            .resume_guard_drain()
            .map_err(|e| format!("{e:?}"))
    }

    fn drain(&self) -> Result<(), String> {
        self.manager.request_drain().map_err(|e| format!("{e:?}"))
    }

    fn graceful_unload(&self) -> Result<(), String> {
        self.manager.guard_stop(false).map_err(|e| format!("{e:?}"))
    }

    fn emergency_stop(&self) -> Result<(), String> {
        self.manager.guard_stop(true).map_err(|e| format!("{e:?}"))
    }

    fn engine_loading(&self) -> bool {
        self.manager.is_transitioning()
    }

    fn engine_active(&self) -> bool {
        // Treat loading and replacing engines as active so the guard cannot de-escalate while they still allocate memory.
        self.manager.is_active() || self.manager.is_transitioning()
    }
}

/// Use inert engine control only for tests or deployments without an engine.
#[derive(Debug, Default)]
pub struct NoEngine;

impl EngineControl for NoEngine {
    fn drain(&self) -> Result<(), String> {
        Ok(())
    }

    fn graceful_unload(&self) -> Result<(), String> {
        Ok(())
    }

    fn emergency_stop(&self) -> Result<(), String> {
        Ok(())
    }

    fn engine_active(&self) -> bool {
        false
    }
}

/// Keep recent raw samples in a bounded memory ring; persist transition evidence as events.
const DIAGNOSTIC_SAMPLES: usize = 120;

#[derive(Debug, Clone, Copy)]
struct DiagnosticSample {
    at_secs: u64,
    available_bytes: u64,
    psi_some_avg10: f64,
    psi_full_avg10: f64,
}

/// Shared guard readings consumed by status/admission surfaces.
#[derive(Debug, Clone)]
pub struct GuardReading {
    pub state: PressureState,
    pub available_bytes: u64,
    pub total_bytes: u64,
}

pub struct MemoryGuardService {
    machine: Mutex<PressureStateMachine>,
    /// Evaluate thermal pressure from the same samples with separate, narrower actions.
    thermal: Mutex<ThermalStateMachine>,
    source: Arc<dyn MemorySource>,
    engine: Arc<dyn EngineControl>,
    events: EventBus,
    database: Option<Arc<Mutex<Connection>>>,
    active: Mutex<Option<ActiveProfile>>,
    diagnostics: Mutex<Vec<DiagnosticSample>>,
    diagnostics_enabled: Arc<AtomicBool>,
    drain_pending: AtomicBool,
}

impl MemoryGuardService {
    #[allow(clippy::too_many_arguments)]
    fn new(
        policy: MemoryPolicy,
        source: Arc<dyn MemorySource>,
        engine: Arc<dyn EngineControl>,
        events: EventBus,
        database: Option<Arc<Mutex<Connection>>>,
    ) -> Self {
        Self {
            machine: Mutex::new(PressureStateMachine::new(policy)),
            thermal: Mutex::new(ThermalStateMachine::new(ThermalPolicy::default())),
            source,
            engine,
            events,
            database,
            active: Mutex::new(None),
            diagnostics: Mutex::new(Vec::new()),
            diagnostics_enabled: Arc::new(AtomicBool::new(false)),
            drain_pending: AtomicBool::new(false),
        }
    }

    /// Persist pressure events before live publication in production.
    pub fn with_database(
        policy: MemoryPolicy,
        source: Arc<dyn MemorySource>,
        engine: Arc<dyn EngineControl>,
        events: EventBus,
        database: Arc<Mutex<Connection>>,
    ) -> Self {
        Self::new(policy, source, engine, events, Some(database))
    }

    /// Use sequence-zero nondurable events only for isolated tests and development, excluding them from SSE.
    #[doc(hidden)]
    pub fn without_database_for_testing(
        policy: MemoryPolicy,
        source: Arc<dyn MemorySource>,
        engine: Arc<dyn EngineControl>,
        events: EventBus,
    ) -> Self {
        Self::new(policy, source, engine, events, None)
    }

    /// The profile currently loaded; set by the engine lifecycle.
    pub fn set_active_profile(&self, active: Option<ActiveProfile>) {
        *self.active.lock() = active;
    }

    /// Configure owner-selected thermal thresholds during composition.
    pub fn with_thermal_policy(self, policy: ThermalPolicy) -> Self {
        *self.thermal.lock() = ThermalStateMachine::new(policy);
        self
    }

    pub fn with_technical_diagnostics(mut self, enabled: Arc<AtomicBool>) -> Self {
        self.diagnostics_enabled = enabled;
        self
    }

    pub fn reading(&self) -> GuardReading {
        let signals = self.source.signals();
        GuardReading {
            state: self.machine.lock().state(),
            available_bytes: signals.available_bytes,
            total_bytes: signals.total_bytes,
        }
    }

    /// Advance one sample with injected time and I/O, returning any pressure transition.
    pub fn tick(&self, now: Duration, node_id: &str) -> Option<PressureTransition> {
        let signals = self.source.signals();
        if self.diagnostics_enabled.load(Ordering::Relaxed) {
            let mut diagnostics = self.diagnostics.lock();
            if diagnostics.len() == DIAGNOSTIC_SAMPLES {
                diagnostics.remove(0);
            }
            diagnostics.push(DiagnosticSample {
                at_secs: now.as_secs(),
                available_bytes: signals.available_bytes,
                psi_some_avg10: signals.psi_some_avg10,
                psi_full_avg10: signals.psi_full_avg10,
            });
        } else {
            self.diagnostics.lock().clear();
        }

        let context = ObservationContext {
            engine_active: self.engine.engine_active(),
            engine_loading: self.engine.engine_loading(),
        };
        let transition = self.machine.lock().observe(&signals, context, now);
        if let Some(transition) = &transition {
            self.act(transition, &signals, node_id);
        }

        // Retry latched Critical or Emergency stops while an engine remains active, including after load transitions initially refuse them.
        if self.engine.engine_active() {
            match self.machine.lock().state() {
                PressureState::Emergency => {
                    let _ = self.engine.emergency_stop();
                }
                PressureState::Critical => {
                    let _ = self.engine.graceful_unload();
                }
                _ => {}
            }
        }

        // Dispatch thermal pressure separately so overheating does not become a memory diagnosis.
        let thermal = self.thermal.lock().observe(&signals.thermal(), now);
        if let Some(thermal) = &thermal {
            self.act_thermal(thermal, node_id);
        }

        let memory_safe = matches!(
            self.machine.lock().state(),
            PressureState::Normal | PressureState::Warning
        );
        let thermal_safe = matches!(
            self.thermal.lock().state(),
            ThermalState::Nominal | ThermalState::Warm
        );
        if memory_safe
            && thermal_safe
            && self.drain_pending.load(Ordering::Acquire)
            && self.engine.resume().is_ok()
        {
            self.drain_pending.store(false, Ordering::Release);
        }
        transition
    }

    /// The current thermal rung, for status surfaces.
    pub fn thermal_state(&self) -> ThermalState {
        self.thermal.lock().state()
    }

    /// Publish the thresholds behind the rung so a client never re-derives them from a raw temperature.
    pub fn thermal_policy(&self) -> ThermalPolicy {
        *self.thermal.lock().policy()
    }

    /// Thermal pressure may drain or gracefully unload, but never emergency-kill or permanently mark a model profile unsafe.
    fn act_thermal(&self, transition: &ThermalTransition, node_id: &str) {
        let severity = match transition.action {
            MemoryAction::GracefulUnload => "error",
            MemoryAction::StopAdmissions => "warning",
            _ => "notice",
        };
        self.emit_event(
            node_id,
            "node.temperature.warning",
            severity,
            json!({
                "from": transition.from.as_str(),
                "to": transition.to.as_str(),
                "reason": transition.reason.as_str(),
                "celsius": transition.celsius,
            }),
        );
        match transition.action {
            MemoryAction::StopAdmissions => {
                if let Err(error) = self.engine.drain() {
                    tracing::warn!(%error, "thermal drain failed");
                } else {
                    self.drain_pending.store(true, Ordering::Release);
                }
            }
            MemoryAction::GracefulUnload => {
                if let Err(error) = self.engine.graceful_unload() {
                    tracing::warn!(%error, "thermal graceful unload failed");
                }
            }
            _ => {}
        }
    }

    /// Sample loop interval from the policy.
    pub fn sample_interval(&self) -> Duration {
        Duration::from_millis(
            self.machine
                .lock()
                .policy()
                .sample_interval_milliseconds
                .max(100),
        )
    }

    /// Current live policy for the signed settings surface.
    pub fn policy(&self) -> MemoryPolicy {
        *self.machine.lock().policy()
    }

    /// Apply validated thresholds and restart evaluation from Normal so old transitions cannot be attributed to new policy.
    pub fn update_policy(&self, policy: MemoryPolicy) {
        *self.machine.lock() = PressureStateMachine::new(policy);
    }

    /// Hold the database lock only while persisting the event before publication.
    fn emit_event(&self, node_id: &str, event_type: &str, severity: &str, payload: Value) {
        match &self.database {
            Some(database) => {
                let conn = database.lock();
                self.events
                    .emit(Some(&conn), node_id, None, event_type, severity, payload);
            }
            None => self
                .events
                .emit(None, node_id, None, event_type, severity, payload),
        }
    }

    fn act(
        &self,
        transition: &PressureTransition,
        signals: &spark_telemetry::MemorySignals,
        node_id: &str,
    ) {
        // Publish the contract pressure projection and internal ladder identifier for each transition.
        self.emit_event(
            node_id,
            "node.memory.pressure.changed",
            severity_for(transition.to),
            json!({
                "from": transition.from.as_str(),
                "to": transition.to.as_str(),
                "api_pressure": transition.to.api_name(),
                "available_bytes": signals.available_bytes,
                "reason": transition.reason.as_str(),
            }),
        );

        match transition.to {
            PressureState::Warning => {
                self.emit_event(
                    node_id,
                    "model.memory.guard.armed",
                    "warning",
                    json!({ "available_bytes": signals.available_bytes }),
                );
            }
            PressureState::Draining => {
                if let Err(error) = self.engine.drain() {
                    tracing::warn!(%error, "engine drain requested by guard failed");
                } else {
                    self.drain_pending.store(true, Ordering::Release);
                }
                self.emit_event(
                    node_id,
                    "model.draining",
                    "warning",
                    json!({ "reason": "memory_pressure" }),
                );
            }
            PressureState::Critical => {
                if let Err(error) = self.engine.graceful_unload() {
                    tracing::error!(%error, "graceful unload requested by guard failed");
                }
            }
            PressureState::Emergency => {
                // Read the resident profile before the stop worker clears it.
                let resident = self.active.lock().clone();
                if let Err(error) = self.engine.emergency_stop() {
                    tracing::error!(%error, "emergency stop requested by guard failed");
                }
                self.mark_profile_unsafe(resident, "memory_guard_emergency", node_id);
                self.emit_event(
                    node_id,
                    "model.memory.guard.triggered",
                    "critical",
                    json!({
                        "reason": transition.reason.as_str(),
                        "available_bytes": signals.available_bytes,
                        "diagnostics": self.diagnostics_payload(),
                    }),
                );
            }
            PressureState::Recovering | PressureState::Normal => {}
        }
    }

    /// Mark the exact failed profile unsafe and exhaust automatic retries.
    fn mark_profile_unsafe(&self, active: Option<ActiveProfile>, reason: &str, node_id: &str) {
        let Some(active) = active else {
            return;
        };
        if let Some(database) = &self.database {
            let conn = database.lock();
            if let Err(error) =
                mark_profile_unsafe(&conn, &active.model_id, &active.profile_id, reason)
            {
                tracing::error!(%error, "failed to mark profile unsafe");
            }
        }
        self.emit_event(
            node_id,
            "model.failed",
            "error",
            json!({
                "model_id": active.model_id,
                "profile_id": active.profile_id,
                "reason": reason,
            }),
        );
    }

    fn diagnostics_payload(&self) -> Value {
        let diagnostics = self.diagnostics.lock();
        json!(
            diagnostics
                .iter()
                .map(|sample| json!({
                    "at_seconds": sample.at_secs,
                    "available_bytes": sample.available_bytes,
                    "psi_some_avg10": sample.psi_some_avg10,
                    "psi_full_avg10": sample.psi_full_avg10,
                }))
                .collect::<Vec<_>>()
        )
    }

    /// Spawn the sampling task. Time advances with the tokio clock.
    pub fn spawn(self: &Arc<Self>, node_id: String, monitor: Arc<dyn SystemMonitor + 'static>) {
        let interval = self.sample_interval();
        let guard = Arc::clone(self);
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(interval);
            loop {
                ticker.tick().await;
                let now = monitor_elapsed(&monitor);
                guard.tick(now, &node_id);
            }
        });
    }
}

/// Use monotonic elapsed time for transitions and wall-clock uptime for meaningful persisted timestamps.
fn monitor_elapsed(monitor: &Arc<dyn SystemMonitor + 'static>) -> Duration {
    Duration::from_secs(monitor.system().uptime_seconds)
}

fn severity_for(state: PressureState) -> &'static str {
    match state {
        PressureState::Normal => "info",
        PressureState::Warning => "warning",
        PressureState::Draining => "error",
        PressureState::Critical => "error",
        PressureState::Emergency => "critical",
        PressureState::Recovering => "notice",
    }
}

mod profile_evidence;
pub use profile_evidence::{
    can_auto_retry, clear_profile_unsafe, consume_auto_retry, mark_profile_unsafe, measured_peak,
    measurement_environment, observed_pressure, profile_is_unsafe, recipe_environment,
    record_profile_peak, recorded_failure,
};

/// Report the active thermal rung and its thresholds identically on status and telemetry.
pub fn thermal_projection(guard: Option<&Arc<MemoryGuardService>>) -> serde_json::Value {
    match guard {
        // `unavailable` says no guard is running; `unknown` says it is running and cannot measure heat.
        None => serde_json::json!({
            "thermal_state": "unavailable",
            "thermal_warning_celsius": null,
            "thermal_hot_celsius": null,
            "thermal_critical_celsius": null,
        }),
        Some(guard) => {
            let policy = guard.thermal_policy();
            serde_json::json!({
                "thermal_state": guard.thermal_state().as_str(),
                "thermal_warning_celsius": policy.warning_celsius,
                "thermal_hot_celsius": policy.hot_celsius,
                "thermal_critical_celsius": policy.critical_celsius,
            })
        }
    }
}
