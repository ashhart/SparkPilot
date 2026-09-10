//! Provide system and inference telemetry, guard state machines, admission, metrics parsing and usage accounting.

pub mod admission;
pub mod classify;
pub mod history;
pub mod pressure;
pub mod proc;
pub mod signals;
pub mod thermal;
pub mod usage;
pub mod vllm;

use serde::Serialize;

pub use admission::{
    AdmissionDecision, AdmissionRequest, DEFAULT_SYSTEM_RESERVE_BYTES, check_admission,
};
pub use classify::{MemoryAction, classify};
pub use history::{
    CompactionOutcome, DEFAULT_AGGREGATE_RETENTION_SECONDS, DEFAULT_RAW_RETENTION_SECONDS,
    HistoryRow, MAX_HISTORY_ROWS, MINUTE_BUCKET_SECONDS, RAW_BUCKET_SECONDS, TelemetrySample,
    bucket_of, compact, history, latest_bucket, purge, record_sample,
};
pub use pressure::{
    ObservationContext, PressureReason, PressureState, PressureStateMachine, PressureTransition,
};
pub use proc::{MemorySource, ProcMonitor};
pub use signals::{MemoryPolicy, MemorySignals};
pub use thermal::{
    ThermalPolicy, ThermalReason, ThermalSignals, ThermalState, ThermalStateMachine,
    ThermalTransition, classify_thermal,
};
pub use usage::{UsageDailyRow, UsageRecord, daily_summary, record_daily};
pub use vllm::{VllmMetrics, parse_vllm_metrics};

/// Unified-memory pressure bucket (matches §33.3 state names).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum MemoryPressure {
    Normal,
    Warning,
    Draining,
    Critical,
    Emergency,
    Recovering,
}

impl MemoryPressure {
    /// The four-value API projection (§26 `SystemStatus.memory_pressure`).
    pub fn api_name(self) -> &'static str {
        match self {
            MemoryPressure::Normal => "normal",
            MemoryPressure::Warning => "warning",
            MemoryPressure::Draining | MemoryPressure::Critical | MemoryPressure::Recovering => {
                "critical"
            }
            MemoryPressure::Emergency => "emergency",
        }
    }
}

/// Point-in-time system snapshot (§26 `system` block, §34.1).
#[derive(Debug, Clone, Serialize)]
pub struct SystemSnapshot {
    pub unified_memory_total_bytes: u64,
    pub unified_memory_available_bytes: u64,
    pub memory_pressure: MemoryPressure,
    pub cpu_utilisation: f64,
    pub load_average_1m: f64,
    pub disk_free_bytes: u64,
    pub temperature_celsius: Option<f64>,
    pub power_state: String,
    pub uptime_seconds: u64,
}

/// Point-in-time inference snapshot (§26 `inference` block).
#[derive(Debug, Clone, Serialize)]
pub struct InferenceSnapshot {
    pub state: String,
    pub model_id: Option<String>,
    pub profile_id: Option<String>,
    pub context_length: Option<u32>,
    pub active_requests: u32,
    pub queue_depth: Option<u32>,
    pub tokens_per_second: Option<f64>,
    pub time_to_first_token_ms: Option<f64>,
}

/// Keep accelerator fields optional so driver startup, updates or failed probes do not make the runtime unavailable.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct AcceleratorSnapshot {
    /// GPU busy time expressed as a fraction in `0...1`.
    pub utilisation: Option<f64>,
    pub temperature_celsius: Option<f64>,
    pub power_draw_watts: Option<f64>,
    pub power_limit_watts: Option<f64>,
    pub memory_used_bytes: Option<u64>,
    pub memory_total_bytes: Option<u64>,
}

/// Capacity of the filesystem that owns the Spark runtime data directory.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct StorageSnapshot {
    pub total_bytes: u64,
    pub free_bytes: u64,
}

/// Keep rich dashboard hardware probes separate from the inexpensive admission snapshot.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct HardwareSnapshot {
    pub accelerator: AcceleratorSnapshot,
    pub storage: StorageSnapshot,
    pub memory_psi_some_avg10: Option<f64>,
    pub memory_psi_full_avg10: Option<f64>,
}

impl Default for InferenceSnapshot {
    fn default() -> Self {
        Self {
            state: "unloaded".to_owned(),
            model_id: None,
            profile_id: None,
            context_length: None,
            active_requests: 0,
            queue_depth: None,
            tokens_per_second: None,
            time_to_first_token_ms: None,
        }
    }
}

/// Abstract platform telemetry so services and handlers can use deterministic monitors.
pub trait SystemMonitor: Send + Sync {
    fn system(&self) -> SystemSnapshot;
    fn inference(&self) -> InferenceSnapshot;

    fn hardware(&self) -> HardwareSnapshot {
        HardwareSnapshot::default()
    }
}

/// Reference fake: 128 GiB total, about 26.8 GiB available and normal pressure (§26).
#[derive(Debug)]
pub struct FakeSystemMonitor;

impl SystemMonitor for FakeSystemMonitor {
    fn system(&self) -> SystemSnapshot {
        SystemSnapshot {
            unified_memory_total_bytes: 137_438_953_472, // 128 GiB
            unified_memory_available_bytes: 28_743_895_347,
            memory_pressure: MemoryPressure::Normal,
            cpu_utilisation: 0.18,
            load_average_1m: 1.2,
            disk_free_bytes: 91_827_364_512,
            temperature_celsius: Some(52.0),
            power_state: "normal".to_owned(),
            uptime_seconds: 123_456,
        }
    }

    fn inference(&self) -> InferenceSnapshot {
        InferenceSnapshot::default()
    }

    fn hardware(&self) -> HardwareSnapshot {
        HardwareSnapshot {
            accelerator: AcceleratorSnapshot {
                utilisation: Some(0.42),
                temperature_celsius: Some(52.0),
                power_draw_watts: Some(48.5),
                power_limit_watts: Some(140.0),
                memory_used_bytes: Some(34_359_738_368),
                memory_total_bytes: Some(137_438_953_472),
            },
            storage: StorageSnapshot {
                total_bytes: 1_000_000_000_000,
                free_bytes: 91_827_364_512,
            },
            memory_psi_some_avg10: Some(0.0),
            memory_psi_full_avg10: Some(0.0),
        }
    }
}
