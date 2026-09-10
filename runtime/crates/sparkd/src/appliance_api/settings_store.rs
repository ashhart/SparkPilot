use super::*;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct MemoryGuardConfig {
    pub warning_available_bytes: u64,
    pub critical_available_bytes: u64,
    pub emergency_available_bytes: u64,
}

impl Default for MemoryGuardConfig {
    fn default() -> Self {
        let policy = MemoryPolicy::default();
        Self {
            warning_available_bytes: policy.warning_available_bytes,
            critical_available_bytes: policy.critical_available_bytes,
            emergency_available_bytes: policy.emergency_available_bytes,
        }
    }
}

impl MemoryGuardConfig {
    pub(super) fn validate(self) -> Result<Self, &'static str> {
        const GIB: u64 = 1024 * 1024 * 1024;
        if self.emergency_available_bytes < GIB
            || self.critical_available_bytes <= self.emergency_available_bytes
            || self.warning_available_bytes <= self.critical_available_bytes
        {
            return Err("memory thresholds must descend from warning to critical to emergency");
        }
        Ok(self)
    }

    pub(super) fn apply_to(self, mut policy: MemoryPolicy) -> MemoryPolicy {
        policy.warning_available_bytes = self.warning_available_bytes;
        policy.critical_available_bytes = self.critical_available_bytes;
        policy.emergency_available_bytes = self.emergency_available_bytes;
        policy
    }
}

/// Apply saved owner thresholds at startup, falling back to packaged defaults if local state is absent or corrupt.
pub fn persisted_memory_policy(
    connection: &rusqlite::Connection,
    fallback: MemoryPolicy,
) -> MemoryPolicy {
    let saved = load_setting::<MemoryGuardConfig>(connection, MEMORY_KEY)
        .ok()
        .flatten()
        .and_then(|config| config.validate().ok());
    match saved {
        Some(config) => config.apply_to(fallback),
        None => fallback,
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModelIdlePolicyConfig {
    pub model_id: String,
    pub profile_id: String,
    pub idle_policy: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idle_timeout_seconds: Option<u64>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct TelemetryConsentConfig {
    pub functional: bool,
    pub technical: bool,
}

pub fn persisted_telemetry_consent(connection: &rusqlite::Connection) -> TelemetryConsentConfig {
    load_setting(connection, TELEMETRY_KEY)
        .ok()
        .flatten()
        .unwrap_or_default()
}

pub(super) fn load_setting<T: DeserializeOwned>(
    connection: &rusqlite::Connection,
    key: &str,
) -> Result<Option<T>, rusqlite::Error> {
    let mut statement =
        connection.prepare("SELECT value_json FROM appliance_settings WHERE setting_key = ?1")?;
    let mut rows = statement.query([key])?;
    let Some(row) = rows.next()? else {
        return Ok(None);
    };
    let raw: String = row.get(0)?;
    serde_json::from_str(&raw).map(Some).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
    })
}

pub(super) fn store_setting<T: Serialize>(
    connection: &rusqlite::Connection,
    key: &str,
    value: &T,
    updated_at: &str,
    device_id: Uuid,
) -> Result<(), rusqlite::Error> {
    let raw = serde_json::to_string(value)
        .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
    connection.execute(
        "INSERT INTO appliance_settings(setting_key, value_json, updated_at, updated_by_device_id)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(setting_key) DO UPDATE SET
           value_json = excluded.value_json,
           updated_at = excluded.updated_at,
           updated_by_device_id = excluded.updated_by_device_id",
        rusqlite::params![key, raw, updated_at, device_id.to_string()],
    )?;
    Ok(())
}

pub(super) fn load_idle_policies(
    connection: &rusqlite::Connection,
) -> Result<Vec<ModelIdlePolicyConfig>, rusqlite::Error> {
    let mut statement = connection.prepare(
        "SELECT p.model_id, p.profile_id, p.idle_policy, t.timeout_seconds
         FROM model_idle_policies p LEFT JOIN model_idle_timeouts t
         ON p.model_id = t.model_id AND p.profile_id = t.profile_id
         ORDER BY p.model_id, p.profile_id",
    )?;
    statement
        .query_map([], |row| {
            Ok(ModelIdlePolicyConfig {
                model_id: row.get(0)?,
                profile_id: row.get(1)?,
                idle_policy: row.get(2)?,
                idle_timeout_seconds: row.get(3)?,
            })
        })?
        .collect()
}
