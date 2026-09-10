//! Match memory_guard config defaults; derive draining midway between warning and critical rather than adding a config key.

use serde::Deserialize;

/// One memory observation feeding the guard. All byte values are absolute.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MemorySignals {
    pub available_bytes: u64,
    pub total_bytes: u64,
    /// `some` PSI ten-second average, 0.0–1.0.
    pub psi_some_avg10: f64,
    /// `full` PSI ten-second average, 0.0–1.0.
    pub psi_full_avg10: f64,
    /// Available-memory fall in bytes per second since the previous sample; zero when stable or unknown.
    pub available_drop_bytes_per_second: u64,
    /// A kernel OOM kill was observed since the previous sample.
    pub kernel_oom_event: bool,
    /// Missing accelerator temperature means unmeasurable, not cool.
    pub gpu_celsius: Option<f64>,
    /// Host/package temperature, if a thermal zone was readable.
    pub cpu_celsius: Option<f64>,
}

impl MemorySignals {
    /// A deliberately calm reading used for tests and cold starts.
    pub fn calm(total_bytes: u64) -> Self {
        Self {
            available_bytes: total_bytes,
            total_bytes,
            psi_some_avg10: 0.0,
            psi_full_avg10: 0.0,
            available_drop_bytes_per_second: 0,
            kernel_oom_event: false,
            gpu_celsius: None,
            cpu_celsius: None,
        }
    }

    /// Test/builder helper: the same reading with different headroom.
    pub fn with_available(mut self, available_bytes: u64) -> Self {
        self.available_bytes = available_bytes;
        self
    }

    /// Test/builder helper: the same reading with an accelerator temperature.
    pub fn with_gpu_celsius(mut self, celsius: f64) -> Self {
        self.gpu_celsius = Some(celsius);
        self
    }

    /// Use the hotter reported sensor, or None when both are unavailable.
    pub fn thermal(&self) -> crate::thermal::ThermalSignals {
        crate::thermal::ThermalSignals {
            gpu_celsius: self.gpu_celsius,
            cpu_celsius: self.cpu_celsius,
        }
    }
}

/// Serialize guard thresholds and timings with memory_guard configuration field names.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct MemoryPolicy {
    pub sample_interval_milliseconds: u64,
    pub warning_available_bytes: u64,
    pub critical_available_bytes: u64,
    pub emergency_available_bytes: u64,
    pub warning_psi_some_avg10: f64,
    pub critical_psi_full_avg10: f64,
    pub recovery_hysteresis_seconds: u64,
    pub auto_retry_maximum: u32,
    /// Seconds a worse non-emergency condition must persist before escalation (§33.3).
    pub escalation_minimum_seconds: u64,
    /// Additional headroom above the entry threshold required to clear a state (§33.3).
    pub recovery_hysteresis_bytes: u64,
    /// Drop-rate threshold for the warning-band projected-cliff rule.
    pub emergency_drop_bytes_per_second: u64,
}

impl Default for MemoryPolicy {
    fn default() -> Self {
        Self {
            sample_interval_milliseconds: 1000,
            warning_available_bytes: 17_179_869_184,
            critical_available_bytes: 10_737_418_240,
            emergency_available_bytes: 6_442_450_944,
            warning_psi_some_avg10: 0.25,
            critical_psi_full_avg10: 0.10,
            recovery_hysteresis_seconds: 30,
            auto_retry_maximum: 1,
            escalation_minimum_seconds: 3,
            recovery_hysteresis_bytes: 4 * 1024 * 1024 * 1024,
            emergency_drop_bytes_per_second: 4 * 1024 * 1024 * 1024,
        }
    }
}

impl MemoryPolicy {
    /// Derive draining at the warning/critical midpoint; it is not a configuration key.
    pub fn draining_available_bytes(&self) -> u64 {
        (self.warning_available_bytes + self.critical_available_bytes) / 2
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_contract_config() {
        let policy = MemoryPolicy::default();
        assert_eq!(policy.sample_interval_milliseconds, 1000);
        assert_eq!(policy.warning_available_bytes, 17_179_869_184);
        assert_eq!(policy.critical_available_bytes, 10_737_418_240);
        assert_eq!(policy.emergency_available_bytes, 6_442_450_944);
        assert_eq!(policy.warning_psi_some_avg10, 0.25);
        assert_eq!(policy.critical_psi_full_avg10, 0.10);
        assert_eq!(policy.recovery_hysteresis_seconds, 30);
        assert_eq!(policy.auto_retry_maximum, 1);
    }

    #[test]
    fn draining_threshold_sits_between_warning_and_critical() {
        let policy = MemoryPolicy::default();
        let draining = policy.draining_available_bytes();
        assert!(draining < policy.warning_available_bytes);
        assert!(draining > policy.critical_available_bytes);
    }
}
