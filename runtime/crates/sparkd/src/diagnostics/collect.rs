//! Select diagnostic fields explicitly so newly added secret columns cannot silently gain an export path.

use serde_json::{Value, json};

use super::{
    AUDIT_CHAIN_UNREADABLE, DRIVER_VERSION_UNREADABLE, INTEGRITY_CHECK_FAILED,
    NETWORK_INVENTORY_UNAVAILABLE, NO_DATABASE, NO_PRIVILEGED_BOUNDARY, OS_RELEASE_UNREADABLE,
    SECTION_QUERY_FAILED, unavailable_code,
};

use crate::state::AppState;

/// Bound growing-table reads because support bundles are snapshots rather than database exports.
const MAX_OPERATIONS: usize = 50;

pub(super) const MAX_OPERATION_STAGES: usize = 200;

const MAX_EVENTS: usize = 200;

const MAX_PRESSURE_TRANSITIONS: usize = 50;

const MAX_CLUSTER_TESTS: usize = 20;

const MAX_MODELS: usize = 100;

const MAX_MODEL_PROFILES: usize = 400;

const MAX_CLUSTER_MEMBERS: usize = 16;

/// Allowlist pressure-state vocabulary instead of copying arbitrary timeline payload strings.
const PRESSURE_STATES: &[&str] = &[
    "normal",
    "warning",
    "draining",
    "critical",
    "emergency",
    "recovering",
];

/// Why the ladder moved (`spark_telemetry::PressureReason`).
const PRESSURE_REASONS: &[&str] = &[
    "escalated",
    "immediate_emergency",
    "recovered",
    "engine_stopped_verifying",
    "re_escalated",
];

/// Remote-access postures the runtime records.
const REMOTE_MODES: &[&str] = &["disabled", "private_overlay"];

const REMOTE_HEALTH: &[&str] = &["starting", "healthy", "degraded", "failed", "disabled"];

/// Allowlisted cluster validation stages.
const CLUSTER_STAGES: &[&str] = &["link", "collective"];

/// Allowlist failure reasons while excluding free-text link-probe details.
const CLUSTER_REASONS: &[&str] = &[
    "link_probe_failed",
    "collective_test_skipped",
    "collective_test_failed",
    "unreachable",
];

/// Power states the telemetry layer reports.
const POWER_STATES: &[&str] = &["normal", "constrained", "throttled", "unknown"];

/// Keep release tokens short and printable so malformed host files cannot inject unrestricted prose.
fn release_token(value: &str) -> Option<String> {
    let acceptable = !value.is_empty()
        && value.len() <= 96
        && value
            .chars()
            .all(|character| character.is_ascii_graphic() || character == ' ');
    acceptable.then(|| value.to_owned())
}

/// Retain only allowlisted values, including when future event writers add unrestricted text.
fn allowlisted(value: Option<&Value>, allowed: &[&'static str]) -> Option<&'static str> {
    let candidate = value?.as_str()?;
    allowed
        .iter()
        .find(|permitted| **permitted == candidate)
        .copied()
}

/// Accept only short interface names within the permitted alphabet.
fn interface_name(value: &Value) -> Option<String> {
    let candidate = value.as_str()?;
    let plausible = !candidate.is_empty()
        && candidate.len() <= 16
        && candidate.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.')
        });
    plausible.then(|| candidate.to_owned())
}

/// Bound query rows and report fixed failure codes instead of silently empty sections or path-bearing SQLite errors.
fn bounded_rows<F>(state: &AppState, sql: &str, limit: usize, map: F) -> Value
where
    F: Fn(&rusqlite::Row<'_>) -> rusqlite::Result<Value>,
{
    let Some(database) = state.database.as_ref() else {
        return unavailable_code(NO_DATABASE);
    };
    let connection = database.lock();
    let Ok(mut statement) = connection.prepare(sql) else {
        return unavailable_code(SECTION_QUERY_FAILED);
    };
    let Ok(rows) = statement.query_map([limit as i64], |row| map(row)) else {
        return unavailable_code(SECTION_QUERY_FAILED);
    };
    let collected: Vec<Value> = rows.filter_map(Result::ok).collect();
    json!({ "available": true, "limit": limit, "rows": collected })
}

/// Return an optional readable row; callers choose section-specific behavior for absent or unreadable data.
pub(super) fn read_row<F>(state: &AppState, sql: &str, map: F) -> Option<Value>
where
    F: FnOnce(&rusqlite::Row<'_>) -> rusqlite::Result<Value>,
{
    let database = state.database.as_ref()?;
    let connection = database.lock();
    connection.query_row(sql, [], map).ok()
}

mod host;
pub(super) use host::{
    host_paths_section, host_section, network_section, runtime_section, services_section,
};

mod database;
pub(super) use database::{
    audit_section, cluster_section, database_section, events_section, memory_pressure_section,
    models_section, operation_stages_section, operations_section,
};
