//! Load the packaged TOML shape; claim effectiveness only for consumed settings exercised by composition tests.

use std::path::Path;
use std::path::PathBuf;

use serde::Deserialize;
use spark_telemetry::MemoryPolicy;
use spark_telemetry::thermal::ThermalPolicy;

/// Map memory_guard keys into MemoryPolicy, permitting explicit escalation dwell, hysteresis and drop-velocity overrides.
#[derive(Debug, Clone, Copy, Default, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct MemoryGuardSettings {
    pub sample_interval_milliseconds: Option<u64>,
    pub warning_available_bytes: Option<u64>,
    pub critical_available_bytes: Option<u64>,
    pub emergency_available_bytes: Option<u64>,
    pub warning_psi_some_avg10: Option<f64>,
    pub critical_psi_full_avg10: Option<f64>,
    pub recovery_hysteresis_seconds: Option<u64>,
    pub auto_retry_maximum: Option<u32>,
    pub escalation_minimum_seconds: Option<u64>,
    pub recovery_hysteresis_bytes: Option<u64>,
    pub emergency_drop_bytes_per_second: Option<u64>,
}

impl MemoryGuardSettings {
    /// Overlay onto the defaults; every key is optional.
    pub fn into_policy(self) -> MemoryPolicy {
        let mut policy = MemoryPolicy::default();
        let s = self;
        if let Some(v) = s.sample_interval_milliseconds {
            policy.sample_interval_milliseconds = v;
        }
        if let Some(v) = s.warning_available_bytes {
            policy.warning_available_bytes = v;
        }
        if let Some(v) = s.critical_available_bytes {
            policy.critical_available_bytes = v;
        }
        if let Some(v) = s.emergency_available_bytes {
            policy.emergency_available_bytes = v;
        }
        if let Some(v) = s.warning_psi_some_avg10 {
            policy.warning_psi_some_avg10 = v;
        }
        if let Some(v) = s.critical_psi_full_avg10 {
            policy.critical_psi_full_avg10 = v;
        }
        if let Some(v) = s.recovery_hysteresis_seconds {
            policy.recovery_hysteresis_seconds = v;
        }
        if let Some(v) = s.auto_retry_maximum {
            policy.auto_retry_maximum = v;
        }
        if let Some(v) = s.escalation_minimum_seconds {
            policy.escalation_minimum_seconds = v;
        }
        if let Some(v) = s.recovery_hysteresis_bytes {
            policy.recovery_hysteresis_bytes = v;
        }
        if let Some(v) = s.emergency_drop_bytes_per_second {
            policy.emergency_drop_bytes_per_second = v;
        }
        policy
    }
}

/// §34.4's default window for aggregated usage rows.
pub const DEFAULT_USAGE_RETENTION_DAYS: u64 = 90;

/// `[telemetry]` (§34.3): refresh and retention knobs.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct TelemetrySettings {
    pub visible_refresh_hz: Option<f64>,
    pub persist_usage_daily: Option<bool>,
    pub retain_raw_inference_events_days: Option<u64>,
    pub retain_operation_events_days: Option<u64>,
    /// Accept this compatibility key without pruning append-only audit rows, which would invalidate the hash chain.
    pub retain_audit_days: Option<u64>,
    /// §34.4: how long aggregated per-day usage is kept; 0 keeps it indefinitely.
    pub usage_retention_days: Option<u64>,
}

impl Default for TelemetrySettings {
    fn default() -> Self {
        Self {
            visible_refresh_hz: Some(1.0),
            persist_usage_daily: Some(true),
            retain_raw_inference_events_days: Some(7),
            retain_operation_events_days: Some(30),
            retain_audit_days: Some(90),
            usage_retention_days: Some(DEFAULT_USAGE_RETENTION_DAYS),
        }
    }
}

/// `[cluster]` (§35): two-Spark cluster inputs.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct ClusterSettings {
    /// Require the deployment's explicit pinned collective image rather than selecting or pulling an unreviewed default.
    pub collective_image_digest: Option<String>,
}

impl ClusterSettings {
    pub fn validate(&self) -> Result<(), String> {
        match self.collective_image_digest.as_deref() {
            None => Ok(()),
            Some(digest) if digest.contains("@sha256:") => Ok(()),
            Some(_) => {
                Err("collective_image_digest must be digest-pinned (image@sha256:...)".into())
            }
        }
    }
}

/// `[operations]` (§27.3): worker lease and renewal cadence.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct OperationSettings {
    pub worker_count: u64,
    pub lease_seconds: i64,
    pub heartbeat_seconds: u64,
    pub event_replay_minimum_count: u64,
    pub event_replay_minimum_hours: u64,
}

const MINIMUM_MODEL_SYSTEM_RESERVE_BYTES: u64 = 8 * 1024 * 1024 * 1024;

/// `[models]` (§29-30): signed catalogue inputs and the two storage roots.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct ModelSettings {
    pub catalogue_path: Option<PathBuf>,
    pub catalogue_root_key_path: Option<PathBuf>,
    /// Fall back to the package's immutable catalogue when the live copy fails verification; default beside the root key.
    pub bootstrap_catalogue_path: Option<PathBuf>,
    pub models_dir: Option<PathBuf>,
    pub downloads_dir: Option<PathBuf>,
    pub one_heavy_model_per_node: Option<bool>,
    /// Existing installations used the shorter name; load() applies today's safety floor.
    #[serde(alias = "system_reserve_bytes")]
    pub minimum_system_reserve_bytes: Option<u64>,
    pub minimum_free_disk_bytes: Option<u64>,
    pub health_check_timeout_seconds: Option<u64>,
    pub drain_timeout_seconds: Option<u64>,
    pub unload_memory_recovery_timeout_seconds: Option<u64>,
}

impl ModelSettings {
    fn validate(&self) -> Result<(), String> {
        if self.one_heavy_model_per_node == Some(false) {
            return Err("one_heavy_model_per_node must remain true in V1".into());
        }
        if self
            .minimum_system_reserve_bytes
            .is_some_and(|bytes| bytes < MINIMUM_MODEL_SYSTEM_RESERVE_BYTES)
        {
            return Err("minimum_system_reserve_bytes must be at least 8 GiB".into());
        }
        if self
            .minimum_free_disk_bytes
            .is_some_and(|bytes| bytes < 1024 * 1024 * 1024)
        {
            return Err("minimum_free_disk_bytes must be at least 1 GiB".into());
        }
        for (name, value) in [
            (
                "health_check_timeout_seconds",
                self.health_check_timeout_seconds,
            ),
            ("drain_timeout_seconds", self.drain_timeout_seconds),
            (
                "unload_memory_recovery_timeout_seconds",
                self.unload_memory_recovery_timeout_seconds,
            ),
        ] {
            if value == Some(0) {
                return Err(format!("{name} must be greater than zero"));
            }
        }
        for (name, path) in [
            ("catalogue_path", self.catalogue_path.as_ref()),
            (
                "catalogue_root_key_path",
                self.catalogue_root_key_path.as_ref(),
            ),
            (
                "bootstrap_catalogue_path",
                self.bootstrap_catalogue_path.as_ref(),
            ),
            ("models_dir", self.models_dir.as_ref()),
            ("downloads_dir", self.downloads_dir.as_ref()),
        ] {
            if path.is_some_and(|path| !path.is_absolute()) {
                return Err(format!("{name} must be an absolute path"));
            }
        }
        Ok(())
    }
}

impl Default for OperationSettings {
    fn default() -> Self {
        Self {
            worker_count: 4,
            lease_seconds: 30,
            heartbeat_seconds: 10,
            event_replay_minimum_count: 10_000,
            event_replay_minimum_hours: 24,
        }
    }
}

impl OperationSettings {
    pub fn lease_config(self) -> crate::jobs::LeaseConfig {
        crate::jobs::LeaseConfig {
            lease_seconds: self.lease_seconds.max(2),
            heartbeat_seconds: self
                .heartbeat_seconds
                .clamp(1, (self.lease_seconds.max(2) - 1) as u64),
            // Clamp reported worker capacity consistently with the pool's minimum of one.
            worker_count: self.worker_count.max(1) as usize,
        }
    }
}

/// Loaded runtime settings.
#[derive(Debug, Clone, Default)]
pub struct Settings {
    pub memory_guard: MemoryPolicy,
    /// Use ThermalPolicy's defaults and unknown-key rejection directly for partial thermal_guard tables.
    pub thermal_guard: ThermalPolicy,
    pub telemetry: TelemetrySettings,
    pub operations: OperationSettings,
    pub models: ModelSettings,
    pub cluster: ClusterSettings,
}

#[derive(Debug, thiserror::Error)]
pub enum SettingsError {
    #[error("failed to read settings: {0}")]
    Io(#[from] std::io::Error),
    #[error("failed to parse settings: {0}")]
    Parse(String),
}

/// Retain unconsumed top-level settings for packaging compatibility while consumed sections reject unknown fields.
pub fn load(path: &Path) -> Result<Settings, SettingsError> {
    let text = std::fs::read_to_string(path)?;
    let parsed: toml::Value = text
        .parse::<toml::Value>()
        .map_err(|e| SettingsError::Parse(e.to_string()))?;
    let mut settings = Settings::default();

    if let Some(section) = parsed.get("memory_guard") {
        let guard: MemoryGuardSettings = section
            .clone()
            .try_into::<MemoryGuardSettings>()
            .map_err(|e| SettingsError::Parse(format!("memory_guard: {e}")))?;
        settings.memory_guard = guard.into_policy();
    }
    if let Some(section) = parsed.get("thermal_guard") {
        settings.thermal_guard = section
            .clone()
            .try_into::<ThermalPolicy>()
            .map_err(|e| SettingsError::Parse(format!("thermal_guard: {e}")))?;
    }
    if let Some(section) = parsed.get("telemetry") {
        let telemetry: TelemetrySettings = section
            .clone()
            .try_into::<TelemetrySettings>()
            .map_err(|e| SettingsError::Parse(format!("telemetry: {e}")))?;
        settings.telemetry = telemetry;
    }
    if let Some(section) = parsed.get("operations") {
        let operations: OperationSettings = section
            .clone()
            .try_into::<OperationSettings>()
            .map_err(|e| SettingsError::Parse(format!("operations: {e}")))?;
        settings.operations = operations;
    }
    if let Some(section) = parsed.get("cluster") {
        let cluster: ClusterSettings = section
            .clone()
            .try_into::<ClusterSettings>()
            .map_err(|error| SettingsError::Parse(format!("cluster: {error}")))?;
        cluster
            .validate()
            .map_err(|error| SettingsError::Parse(format!("cluster: {error}")))?;
        settings.cluster = cluster;
    }
    if let Some(section) = parsed.get("models") {
        let mut models: ModelSettings = section
            .clone()
            .try_into::<ModelSettings>()
            .map_err(|e| SettingsError::Parse(format!("models: {e}")))?;
        // Accept legacy configuration files while retaining the current model admission floor.
        if section.get("system_reserve_bytes").is_some()
            && let Some(previous) = models.minimum_system_reserve_bytes
        {
            let effective = previous.max(MINIMUM_MODEL_SYSTEM_RESERVE_BYTES);
            models.minimum_system_reserve_bytes = Some(effective);
            tracing::info!(
                previous,
                effective,
                "using legacy system_reserve_bytes as minimum_system_reserve_bytes"
            );
        }
        models
            .validate()
            .map_err(|e| SettingsError::Parse(format!("models: {e}")))?;
        settings.models = models;
    }

    Ok(settings)
}

/// §60.3: derive the per-class event retention the housekeeping sweep applies.
impl Settings {
    pub fn event_retention(&self) -> crate::events::EventRetention {
        let defaults = crate::events::EventRetention::default();
        crate::events::EventRetention {
            replay_minimum_rows: usize::try_from(self.operations.event_replay_minimum_count)
                .unwrap_or(defaults.replay_minimum_rows),
            replay_minimum_hours: i64::try_from(self.operations.event_replay_minimum_hours)
                .unwrap_or(defaults.replay_minimum_hours),
            security_days: self
                .telemetry
                .retain_audit_days
                .and_then(|days| i64::try_from(days).ok())
                .unwrap_or(defaults.security_days),
            operation_days: self
                .telemetry
                .retain_operation_events_days
                .and_then(|days| i64::try_from(days).ok())
                .unwrap_or(defaults.operation_days),
            lifecycle_days: self
                .telemetry
                .retain_raw_inference_events_days
                .and_then(|days| i64::try_from(days).ok())
                .unwrap_or(defaults.lifecycle_days),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_example_config_file() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../config/sparkd.example.toml");
        let settings = load(&path).unwrap();
        let policy = settings.memory_guard;
        assert_eq!(policy.sample_interval_milliseconds, 1000);
        assert_eq!(policy.warning_available_bytes, 17_179_869_184);
        assert_eq!(settings.operations.lease_seconds, 30);
        assert_eq!(settings.operations.heartbeat_seconds, 10);
        assert_eq!(policy.critical_available_bytes, 10_737_418_240);
        assert_eq!(policy.emergency_available_bytes, 6_442_450_944);
        assert_eq!(policy.warning_psi_some_avg10, 0.25);
        assert_eq!(policy.critical_psi_full_avg10, 0.10);
        assert_eq!(policy.recovery_hysteresis_seconds, 30);
        assert_eq!(policy.auto_retry_maximum, 1);
        assert_eq!(settings.telemetry.visible_refresh_hz, Some(1.0));
        assert_eq!(settings.telemetry.retain_audit_days, Some(90));
        assert_eq!(
            settings.models.catalogue_path.as_deref(),
            Some(Path::new("/var/lib/spark-runtime/catalogue/catalogue.json"))
        );
        assert_eq!(
            settings.models.catalogue_root_key_path.as_deref(),
            Some(Path::new(
                "/usr/share/spark-runtime/trust/catalogue-root.pub"
            ))
        );
        assert_eq!(
            settings.models.models_dir.as_deref(),
            Some(Path::new("/var/lib/spark-runtime/models"))
        );
        assert_eq!(
            settings.models.downloads_dir.as_deref(),
            Some(Path::new("/var/cache/spark-runtime/downloads"))
        );
    }

    #[test]
    fn missing_file_or_unknown_keys_are_rejected() {
        assert!(load(std::path::Path::new("no-such-file.toml")).is_err());
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("bad.toml");
        std::fs::write(&path, "[memory_guard]\nnot_a_key = 1\n").unwrap();
        assert!(load(&path).is_err());
    }

    #[test]
    fn legacy_model_reserve_remains_loadable_without_lowering_the_safety_floor() {
        let tmp = tempfile::tempdir().unwrap();
        for (legacy, expected) in [
            (6_000_000_000_u64, 8 * 1024 * 1024 * 1024),
            (40_000_000_000, 40_000_000_000),
        ] {
            let path = tmp.path().join(format!("legacy-{legacy}.toml"));
            let contents = format!(
                "[models]\nsystem_reserve_bytes = {legacy}\nhealth_check_timeout_seconds = 900\n"
            );
            std::fs::write(&path, &contents).unwrap();
            let loaded = load(&path).unwrap();
            assert_eq!(loaded.models.minimum_system_reserve_bytes, Some(expected));
            assert_eq!(loaded.models.health_check_timeout_seconds, Some(900));
            assert_eq!(std::fs::read_to_string(path).unwrap(), contents);
        }
    }

    #[test]
    fn conflicting_model_reserve_names_are_rejected() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("conflicting.toml");
        std::fs::write(
            &path,
            "[models]\nsystem_reserve_bytes = 6000000000\nminimum_system_reserve_bytes = 40000000000\n",
        )
        .unwrap();
        assert!(load(&path).is_err());
    }

    #[test]
    fn unsafe_model_policy_is_rejected() {
        let tmp = tempfile::tempdir().unwrap();
        let cases = [
            "[models]\none_heavy_model_per_node = false\n",
            "[models]\nhealth_check_timeout_seconds = 0\n",
            "[models]\nminimum_system_reserve_bytes = 1\n",
            "[models]\nmodels_dir = 'relative/models'\n",
        ];
        for (index, contents) in cases.iter().enumerate() {
            let path = tmp.path().join(format!("bad-{index}.toml"));
            std::fs::write(&path, contents).unwrap();
            assert!(load(&path).is_err(), "accepted {contents:?}");
        }
    }
}
