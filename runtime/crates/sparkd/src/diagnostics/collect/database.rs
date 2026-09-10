use super::*;

pub(in super::super) fn operation_stages_section(state: &AppState) -> Value {
    // Exclude worker-authored details_json from the diagnostic allowlist.
    bounded_rows(
        state,
        "SELECT operation_id, sequence, stage, state, started_at, completed_at \
         FROM operation_stages ORDER BY started_at DESC LIMIT ?1",
        MAX_OPERATION_STAGES,
        |row| {
            Ok(json!({
                "operation_id": row.get::<_, String>(0)?,
                "sequence": row.get::<_, i64>(1)?,
                "stage": row.get::<_, String>(2)?,
                "state": row.get::<_, String>(3)?,
                "started_at": row.get::<_, String>(4)?,
                "completed_at": row.get::<_, Option<String>>(5)?,
            }))
        },
    )
}

pub(in super::super) fn operations_section(state: &AppState) -> Value {
    // Exclude operation input and result JSON because they may contain document or prompt content.
    bounded_rows(
        state,
        "SELECT id, kind, state, stage, created_at, updated_at, completed_at, error_code \
         FROM operations ORDER BY created_at DESC LIMIT ?1",
        MAX_OPERATIONS,
        |row| {
            Ok(json!({
                "id": row.get::<_, String>(0)?,
                "kind": row.get::<_, String>(1)?,
                "state": row.get::<_, String>(2)?,
                "stage": row.get::<_, Option<String>>(3)?,
                "created_at": row.get::<_, String>(4)?,
                "updated_at": row.get::<_, String>(5)?,
                "completed_at": row.get::<_, Option<String>>(6)?,
                "error_code": row.get::<_, Option<String>>(7)?,
            }))
        },
    )
}

pub(in super::super) fn events_section(state: &AppState) -> Value {
    bounded_rows(
        state,
        "SELECT sequence, event_type, severity, occurred_at \
         FROM events ORDER BY sequence DESC LIMIT ?1",
        MAX_EVENTS,
        |row| {
            Ok(json!({
                "sequence": row.get::<_, i64>(0)?,
                "type": row.get::<_, String>(1)?,
                "severity": row.get::<_, String>(2)?,
                "occurred_at": row.get::<_, String>(3)?,
            }))
        },
    )
}

pub(in super::super) fn memory_pressure_section(state: &AppState) -> Value {
    // Select individual pressure-event fields without exporting whole payloads.
    bounded_rows(
        state,
        "SELECT occurred_at, payload_json FROM events \
         WHERE event_type = 'node.memory.pressure.changed' \
         ORDER BY sequence DESC LIMIT ?1",
        MAX_PRESSURE_TRANSITIONS,
        |row| {
            let payload: Value =
                serde_json::from_str(&row.get::<_, String>(1)?).unwrap_or_else(|_| json!({}));
            Ok(json!({
                "occurred_at": row.get::<_, String>(0)?,
                "from": allowlisted(payload.get("from"), PRESSURE_STATES),
                "to": allowlisted(payload.get("to"), PRESSURE_STATES),
                "reason": allowlisted(payload.get("reason"), PRESSURE_REASONS),
                "available_bytes": payload.get("available_bytes").and_then(Value::as_u64),
            }))
        },
    )
}

pub(in super::super) fn models_section(state: &AppState) -> Value {
    // Exclude manifest paths unless the owner selected the optional paths category.
    let models = bounded_rows(
        state,
        "SELECT id, recipe_revision, recipe_digest, source_revision, install_state, \
                total_bytes, measured_peak_bytes, failure_code \
         FROM models ORDER BY id LIMIT ?1",
        MAX_MODELS,
        |row| {
            Ok(json!({
                "model_id": row.get::<_, String>(0)?,
                "recipe_revision": row.get::<_, String>(1)?,
                "recipe_digest": row.get::<_, String>(2)?,
                "source_revision": row.get::<_, String>(3)?,
                "install_state": row.get::<_, String>(4)?,
                "total_bytes": row.get::<_, Option<i64>>(5)?,
                "measured_peak_bytes": row.get::<_, Option<i64>>(6)?,
                "failure_code": row.get::<_, Option<String>>(7)?,
            }))
        },
    );
    let profiles = bounded_rows(
        state,
        "SELECT model_id, profile_id, context_length, expected_peak_bytes, \
                measured_peak_bytes, safe, last_failure_code, last_measured_at \
         FROM model_profiles ORDER BY model_id, profile_id LIMIT ?1",
        MAX_MODEL_PROFILES,
        |row| {
            Ok(json!({
                "model_id": row.get::<_, String>(0)?,
                "profile_id": row.get::<_, String>(1)?,
                "context_length": row.get::<_, i64>(2)?,
                "expected_peak_bytes": row.get::<_, Option<i64>>(3)?,
                "measured_peak_bytes": row.get::<_, Option<i64>>(4)?,
                "safe": row.get::<_, i64>(5)? != 0,
                "last_failure_code": row.get::<_, Option<String>>(6)?,
                "last_measured_at": row.get::<_, Option<String>>(7)?,
            }))
        },
    );
    json!({ "available": true, "models": models, "profiles": profiles })
}

pub(in super::super) fn cluster_section(state: &AppState) -> Value {
    let state_row = read_row(
        state,
        "SELECT id, state, updated_at FROM cluster_state WHERE singleton = 1",
        |row| {
            Ok(json!({
                "cluster_id": row.get::<_, String>(0)?,
                "state": row.get::<_, String>(1)?,
                "updated_at": row.get::<_, String>(2)?,
            }))
        },
    )
    .unwrap_or_else(|| json!({ "state": "standalone" }));

    let members = bounded_rows(
        state,
        "SELECT node_id, role, reachable, qsfp_health, runtime_version, last_seen_at \
         FROM cluster_members ORDER BY node_id LIMIT ?1",
        MAX_CLUSTER_MEMBERS,
        |row| {
            Ok(json!({
                "node_id": row.get::<_, String>(0)?,
                "role": row.get::<_, String>(1)?,
                "reachable": row.get::<_, i64>(2)? != 0,
                "qsfp_health": row.get::<_, Option<String>>(3)?,
                "runtime_version": row.get::<_, Option<String>>(4)?,
                "last_seen_at": row.get::<_, Option<String>>(5)?,
            }))
        },
    );

    // Select closed validation fields without free-text link failures that may reveal interface paths.
    let tests = bounded_rows(
        state,
        "SELECT occurred_at, event_type, payload_json FROM events \
         WHERE event_type IN ('cluster.ready','cluster.degraded','cluster.link.changed', \
                              'cluster.validation.progress') \
         ORDER BY sequence DESC LIMIT ?1",
        MAX_CLUSTER_TESTS,
        |row| {
            let payload: Value =
                serde_json::from_str(&row.get::<_, String>(2)?).unwrap_or_else(|_| json!({}));
            Ok(json!({
                "occurred_at": row.get::<_, String>(0)?,
                "event": row.get::<_, String>(1)?,
                "stage": allowlisted(payload.get("stage"), CLUSTER_STAGES),
                "reason": allowlisted(payload.get("reason"), CLUSTER_REASONS),
                "link_up": payload.get("link_up").and_then(Value::as_bool),
                "interface": payload.get("interface").and_then(interface_name),
            }))
        },
    );

    json!({
        "available": true,
        "cluster": state_row,
        "members": members,
        "validation_tests": tests,
    })
}

pub(in super::super) fn database_section(state: &AppState) -> Value {
    let Some(database) = state.database.as_ref() else {
        return unavailable_code(NO_DATABASE);
    };
    let connection = database.lock();
    let version: Option<i64> = connection
        .query_row("SELECT MAX(version) FROM schema_migrations", [], |row| {
            row.get(0)
        })
        .ok()
        .flatten();
    // Reduce integrity-check output to a verdict so page and index details are not exported.
    let integrity = connection
        .query_row("PRAGMA integrity_check", [], |row| row.get::<_, String>(0))
        .ok()
        .map(|result| result == "ok");

    // Count schema-listed tables with separate prepared queries rather than caller-selected names.
    let mut counts = serde_json::Map::new();
    if let Ok(mut statement) = connection.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' \
         AND name NOT LIKE 'sqlite_%' ORDER BY name",
    ) && let Ok(names) = statement.query_map([], |row| row.get::<_, String>(0))
    {
        for name in names.flatten() {
            // Escape identifier quotes even in schema-derived table names before interpolating SQL.
            let quoted = name.replace('"', "\"\"");
            let count: Option<i64> = connection
                .query_row(&format!("SELECT COUNT(*) FROM \"{quoted}\""), [], |row| {
                    row.get(0)
                })
                .ok();
            counts.insert(name, json!(count));
        }
    }

    json!({
        "available": true,
        "schema_version": version,
        "integrity_check": match integrity {
            Some(true) => json!("ok"),
            Some(false) => json!("failed"),
            None => json!({ "reason_code": INTEGRITY_CHECK_FAILED }),
        },
        "row_counts": counts,
    })
}

pub(in super::super) fn audit_section(state: &AppState) -> Value {
    let Some(database) = state.database.as_ref() else {
        return unavailable_code(NO_DATABASE);
    };
    let connection = database.lock();
    let highest: Option<i64> = connection
        .query_row("SELECT MAX(sequence) FROM audit_records", [], |row| {
            row.get(0)
        })
        .ok()
        .flatten();
    match crate::audit::verify_chain(&connection) {
        // Report the first broken audit sequence, or None when verification passes.
        Ok(None) => json!({
            "available": true,
            "highest_sequence": highest,
            "chain_verified": true,
        }),
        Ok(Some(sequence)) => json!({
            "available": true,
            "highest_sequence": highest,
            "chain_verified": false,
            "first_broken_sequence": sequence,
        }),
        Err(_) => unavailable_code(AUDIT_CHAIN_UNREADABLE),
    }
}
