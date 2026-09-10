use super::*;

/// PLAN 32.3: the exact software a peak was measured under, so a peak taken elsewhere is never mistaken for this one.
pub fn measurement_environment(
    engine_image: &str,
    source_revision: &str,
    recipe_revision: &str,
) -> String {
    crate::crypto::sha256_hex(
        format!(
            "{engine_image}\n{source_revision}\n{recipe_revision}\n{}\n{}",
            spark_core::RUNTIME_VERSION,
            spark_core::host_driver_version().unwrap_or("unknown"),
        )
        .as_bytes(),
    )
}

/// The environment a load of this signed recipe measures in; a re-signed recipe restates its profiles, so its peaks start again.
pub fn recipe_environment(recipe: &spark_models::ModelRecipe) -> String {
    measurement_environment(
        &recipe.engine.image,
        &recipe.source.revision,
        &recipe.metadata.revision,
    )
}

/// Retain the highest measured profile peak within one environment; a changed environment starts again from this load.
pub fn record_profile_peak(
    conn: &Connection,
    model_id: &str,
    profile_id: &str,
    peak_bytes: u64,
    environment: &str,
) -> Result<(), rusqlite::Error> {
    let now = crate::store::now_iso8601();
    conn.execute(
        "UPDATE model_profiles SET
            measured_peak_bytes = CASE
                WHEN measured_environment IS ?5
                    THEN MAX(COALESCE(measured_peak_bytes, 0), ?3)
                ELSE ?3 END,
            measured_environment = ?5,
            last_measured_at = ?4
         WHERE model_id = ?1 AND profile_id = ?2",
        rusqlite::params![model_id, profile_id, peak_bytes, now, environment],
    )?;
    Ok(())
}

/// Require explicit user action before reloading profiles marked unsafe after pressure failure.
pub fn mark_profile_unsafe(
    conn: &Connection,
    model_id: &str,
    profile_id: &str,
    reason: &str,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE model_profiles SET safe = 0, last_failure_code = ?3
         WHERE model_id = ?1 AND profile_id = ?2",
        rusqlite::params![model_id, profile_id, reason],
    )?;
    Ok(())
}

/// After owner review, clear unsafe state, suppressed measurement and exhausted retry budget together; clearing an already-safe profile is idempotent.
pub fn clear_profile_unsafe(
    conn: &Connection,
    model_id: &str,
    profile_id: &str,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE model_profiles SET safe = 1, last_failure_code = NULL, auto_retries = 0
         WHERE model_id = ?1 AND profile_id = ?2",
        rusqlite::params![model_id, profile_id],
    )?;
    Ok(())
}

/// Whether a profile is currently marked unsafe.
pub fn profile_is_unsafe(
    conn: &Connection,
    model_id: &str,
    profile_id: &str,
) -> Result<bool, rusqlite::Error> {
    use rusqlite::OptionalExtension;
    let safe: Option<i64> = conn
        .query_row(
            "SELECT safe FROM model_profiles WHERE model_id = ?1 AND profile_id = ?2",
            rusqlite::params![model_id, profile_id],
            |row| row.get(0),
        )
        .optional()?;
    Ok(safe == Some(0))
}

/// Expose unsafe-profile failure and peak evidence for owner review without treating it as admission-safe measurement.
pub fn recorded_failure(
    conn: &Connection,
    model_id: &str,
    profile_id: &str,
) -> Result<(Option<String>, Option<u64>), rusqlite::Error> {
    use rusqlite::OptionalExtension;
    let row: Option<(Option<String>, Option<i64>)> = conn
        .query_row(
            "SELECT last_failure_code, measured_peak_bytes FROM model_profiles
             WHERE model_id = ?1 AND profile_id = ?2",
            rusqlite::params![model_id, profile_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    Ok(match row {
        Some((code, peak)) => (
            code,
            peak.and_then(|bytes| (bytes > 0).then_some(bytes as u64)),
        ),
        None => (None, None),
    })
}

/// The highest measured peak recorded for a safe profile in this exact environment; anything older is not evidence.
pub fn measured_peak(
    conn: &Connection,
    model_id: &str,
    profile_id: &str,
    environment: &str,
) -> Result<Option<u64>, rusqlite::Error> {
    use rusqlite::OptionalExtension;
    let peak: Option<(Option<i64>, i64, Option<String>)> = conn
        .query_row(
            "SELECT measured_peak_bytes, safe, measured_environment FROM model_profiles
             WHERE model_id = ?1 AND profile_id = ?2",
            rusqlite::params![model_id, profile_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    Ok(match peak {
        Some((Some(bytes), 1, Some(measured_in))) if measured_in == environment => {
            (bytes > 0).then_some(bytes as u64)
        }
        _ => None,
    })
}

/// Report whether policy permits one controlled retry.
pub fn can_auto_retry(
    conn: &Connection,
    model_id: &str,
    profile_id: &str,
    maximum: u32,
) -> Result<bool, rusqlite::Error> {
    use rusqlite::OptionalExtension;
    let retries: Option<i64> = conn
        .query_row(
            "SELECT auto_retries FROM model_profiles
             WHERE model_id = ?1 AND profile_id = ?2",
            rusqlite::params![model_id, profile_id],
            |row| row.get(0),
        )
        .optional()?;
    Ok(retries.unwrap_or(0) < i64::from(maximum))
}

/// Consume one automatic retry slot.
pub fn consume_auto_retry(
    conn: &Connection,
    model_id: &str,
    profile_id: &str,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE model_profiles SET auto_retries = auto_retries + 1
         WHERE model_id = ?1 AND profile_id = ?2",
        rusqlite::params![model_id, profile_id],
    )?;
    Ok(())
}

/// Prefer the continuously sampled guard pressure over monitor defaults so every client reports the same live state.
pub fn observed_pressure(
    guard: Option<&std::sync::Arc<MemoryGuardService>>,
    snapshot: &spark_telemetry::SystemSnapshot,
) -> spark_telemetry::MemoryPressure {
    let Some(guard) = guard else {
        return snapshot.memory_pressure;
    };
    match guard.reading().state {
        spark_telemetry::PressureState::Normal => spark_telemetry::MemoryPressure::Normal,
        spark_telemetry::PressureState::Warning => spark_telemetry::MemoryPressure::Warning,
        spark_telemetry::PressureState::Draining => spark_telemetry::MemoryPressure::Draining,
        spark_telemetry::PressureState::Critical => spark_telemetry::MemoryPressure::Critical,
        spark_telemetry::PressureState::Emergency => spark_telemetry::MemoryPressure::Emergency,
        spark_telemetry::PressureState::Recovering => spark_telemetry::MemoryPressure::Recovering,
    }
}
