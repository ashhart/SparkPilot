//! Expose signed live telemetry separately from heavier catalogue and operation inventory for frequent dashboard refreshes.

use axum::Extension;
use axum::extract::{Query, State};
use axum::response::Json;
use futures::future::join_all;
use serde_json::{Value, json};

use crate::auth::Principal;
use crate::capability::Capability;
use crate::inference_metrics::EngineMetricsTarget;
use crate::state::AppState;

/// The authorisation failure envelope both telemetry reads share.
type TelemetryDenial = (axum::http::StatusCode, Json<Value>);

#[derive(Default)]
struct UsageTotals {
    requests: u64,
    failures: u64,
    prompt_tokens: u64,
    cached_prompt_tokens: u64,
    generated_tokens: u64,
    reasoning_tokens: u64,
}

/// Return one current local telemetry sample to a device that holds `TelemetryRead`.
pub async fn get_telemetry(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, TelemetryDenial> {
    state
        .require(&principal, Capability::TelemetryRead)
        .resource("telemetry")
        .check()?;
    let observed = state.clock.now();
    let usage_day = observed.date().to_string();
    let usage_database = state.database.clone();
    let usage_day_for_query = usage_day.clone();
    let usage_task = tokio::task::spawn_blocking(move || {
        let Some(database) = usage_database else {
            return UsageTotals::default();
        };
        match spark_telemetry::daily_summary(&database.lock(), &usage_day_for_query) {
            Ok(rows) => rows
                .into_iter()
                .fold(UsageTotals::default(), |mut total, row| {
                    total.requests = total.requests.saturating_add(row.requests);
                    total.failures = total.failures.saturating_add(row.failures);
                    total.prompt_tokens = total.prompt_tokens.saturating_add(row.prompt_tokens);
                    total.cached_prompt_tokens = total
                        .cached_prompt_tokens
                        .saturating_add(row.cached_prompt_tokens);
                    total.generated_tokens =
                        total.generated_tokens.saturating_add(row.generated_tokens);
                    total.reasoning_tokens =
                        total.reasoning_tokens.saturating_add(row.reasoning_tokens);
                    total
                }),
            Err(error) => {
                tracing::warn!(%error, "telemetry could not read today's usage totals");
                UsageTotals::default()
            }
        }
    });
    let monitor = state.telemetry.clone();
    let (mut system, hardware) = tokio::task::spawn_blocking(move || {
        let system = monitor.system();
        let hardware = monitor.hardware();
        (system, hardware)
    })
    .await
    .unwrap_or_else(|error| {
        tracing::warn!(%error, "telemetry probe worker failed");
        (
            state.telemetry.system(),
            spark_telemetry::HardwareSnapshot::default(),
        )
    });

    if system.temperature_celsius.is_none() {
        system.temperature_celsius = hardware.accelerator.temperature_celsius;
    }
    // §41.5.2.1: publish the guard's own rung and its thresholds so no client invents a heat verdict.
    let thermal = crate::guard::thermal_projection(state.guard.as_ref());
    let memory_pressure = state.guard.as_ref().map_or_else(
        || system.memory_pressure.api_name(),
        |guard| guard.reading().state.api_name(),
    );
    let mut inference = match &state.engine.manager {
        Some(manager) => manager.inference_active(),
        None => {
            let inference = state.telemetry.inference();
            json!({
                "state": inference.state,
                "model_id": inference.model_id,
                "profile_id": inference.profile_id,
                "context_length": inference.context_length,
                "active_requests": inference.active_requests,
                "queue_depth": inference.queue_depth,
                "tokens_per_second": inference.tokens_per_second,
                "time_to_first_token_ms": inference.time_to_first_token_ms,
            })
        }
    };
    let mut targets = Vec::new();
    if let Some(manager) = &state.engine.manager
        && let (Some(port), Some(view)) = (manager.internal_port(), manager.view())
    {
        let recipe = view.recipe.engine.recipe.to_ascii_lowercase();
        let engine = if recipe.contains("sglang") {
            "sglang"
        } else {
            "vllm"
        };
        targets.push(EngineMetricsTarget::managed(
            engine,
            port,
            Some(view.served_name),
        ));
    }
    // Gate the external-host probe on administrator authority in its own right, so widening TelemetryRead later cannot expose other hosts.
    let external_targets = if crate::capability::Role::parse(&principal.role)
        >= crate::capability::Role::Administrator
    {
        state
            .inference_metrics
            .external_targets(state.privileged.clone())
            .await
    } else {
        Vec::new()
    };
    for target in external_targets {
        if targets.iter().all(|existing| existing.port != target.port) {
            targets.push(target);
        }
    }
    targets.truncate(8);
    let observed_at = observed
        .format(&time::format_description::well_known::Rfc3339)
        .expect("UTC timestamps format as RFC3339");
    let engine_reports = join_all(targets.into_iter().map(|target| {
        state
            .inference_metrics
            .collect(target, observed_at.clone(), observed.unix_timestamp())
    }))
    .await;
    if let Some(primary) = engine_reports
        .iter()
        .find(|report| report.availability == "live" || report.availability == "cached")
        && let Some(fields) = inference.as_object_mut()
    {
        if state.engine.manager.is_none() {
            fields.insert("state".to_owned(), json!("ready"));
            fields.insert("model_id".to_owned(), json!(primary.served_model));
        }
        if let Some(running) = primary.running_requests {
            fields.insert("active_requests".to_owned(), json!(running));
        }
        fields.insert("queue_depth".to_owned(), json!(primary.queue_depth));
        fields.insert(
            "tokens_per_second".to_owned(),
            json!(primary.generation_tokens_per_second),
        );
        fields.insert(
            "time_to_first_token_ms".to_owned(),
            json!(primary.time_to_first_token_ms),
        );
    }
    let usage = usage_task.await.unwrap_or_else(|error| {
        tracing::warn!(%error, "telemetry usage worker failed");
        UsageTotals::default()
    });
    let total_storage = hardware.storage.total_bytes;
    let free_storage = hardware.storage.free_bytes;

    Ok(Json(json!({
        "api_version": state.config.api_major,
        "observed_at": observed_at,
        "node_id": state.identity.node_id(),
        "node_name": state.identity.public.node_name,
        "system": {
            "cpu_utilisation": system.cpu_utilisation,
            "load_average_1m": system.load_average_1m,
            "unified_memory_total_bytes": system.unified_memory_total_bytes,
            "unified_memory_available_bytes": system.unified_memory_available_bytes,
            "unified_memory_used_bytes": system
                .unified_memory_total_bytes
                .saturating_sub(system.unified_memory_available_bytes),
            "memory_pressure": memory_pressure,
            "memory_psi_some_avg10": hardware.memory_psi_some_avg10,
            "memory_psi_full_avg10": hardware.memory_psi_full_avg10,
            "temperature_celsius": system.temperature_celsius,
            "thermal_state": thermal["thermal_state"],
            "thermal_warning_celsius": thermal["thermal_warning_celsius"],
            "thermal_hot_celsius": thermal["thermal_hot_celsius"],
            "thermal_critical_celsius": thermal["thermal_critical_celsius"],
            "power_state": system.power_state,
            "uptime_seconds": system.uptime_seconds,
        },
        "accelerator": {
            "utilisation": hardware.accelerator.utilisation,
            "temperature_celsius": hardware.accelerator.temperature_celsius,
            "power_draw_watts": hardware.accelerator.power_draw_watts,
            "power_limit_watts": hardware.accelerator.power_limit_watts,
            "memory_used_bytes": hardware.accelerator.memory_used_bytes,
            "memory_total_bytes": hardware.accelerator.memory_total_bytes,
        },
        "storage": {
            "total_bytes": total_storage,
            "free_bytes": free_storage,
            "used_bytes": total_storage.saturating_sub(free_storage),
        },
        "usage": {
            "day": usage_day,
            "requests": usage.requests,
            // Report failures as unavailable because this collector does not count them; zero would claim none occurred.
            "failures": Value::Null,
            "prompt_tokens": usage.prompt_tokens,
            "cached_prompt_tokens": usage.cached_prompt_tokens,
            "generated_tokens": usage.generated_tokens,
            "reasoning_tokens": usage.reasoning_tokens,
            "total_tokens": usage.prompt_tokens
                .saturating_add(usage.generated_tokens)
                .saturating_add(usage.reasoning_tokens),
        },
        "inference": inference,
        "engines": engine_reports,
    })))
}

/// Bound history by actual retention and MAX_HISTORY_ROWS, rejecting invalid or inverted ranges.
pub async fn get_telemetry_history(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Query(request): Query<HistoryQuery>,
) -> Result<Json<Value>, TelemetryDenial> {
    state
        .require(&principal, Capability::TelemetryRead)
        .resource("telemetry/history")
        .check()?;
    let now = state.clock.now().unix_timestamp();
    let recording = state.telemetry_consent.read().functional;
    let from = match request.from.as_deref().map(parse_instant).transpose() {
        Ok(value) => value.unwrap_or(now - spark_telemetry::DEFAULT_RAW_RETENTION_SECONDS),
        Err(message) => return Err(invalid_range(message)),
    };
    let to = match request.to.as_deref().map(parse_instant).transpose() {
        Ok(value) => value.unwrap_or(now),
        Err(message) => return Err(invalid_range(message)),
    };
    if from > to {
        return Err(invalid_range("from is after to"));
    }
    let limit = request.limit.unwrap_or(720);
    if limit == 0 || limit > spark_telemetry::MAX_HISTORY_ROWS {
        return Err(invalid_range("limit is outside 1..=2880"));
    }
    // Clamp the oldest timestamp to retained history so an empty unrecorded interval cannot imply inactivity.
    let earliest = now.saturating_sub(spark_telemetry::DEFAULT_AGGREGATE_RETENTION_SECONDS);
    let from = from.max(earliest);

    let Some(database) = state.database.clone() else {
        return Ok(Json(history_envelope(&state, recording, None, Vec::new())));
    };
    let read = tokio::task::spawn_blocking(move || {
        let conn = database.lock();
        let latest = spark_telemetry::latest_bucket(&conn)?;
        let rows = spark_telemetry::history(&conn, from, to, limit)?;
        Ok::<_, rusqlite::Error>((latest, rows))
    })
    .await;
    let (latest, rows) = match read {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => {
            tracing::warn!(%error, "telemetry history could not be read");
            (None, Vec::new())
        }
        Err(error) => {
            tracing::warn!(%error, "telemetry history worker failed");
            (None, Vec::new())
        }
    };
    Ok(Json(history_envelope(&state, recording, latest, rows)))
}

#[derive(serde::Deserialize)]
pub struct HistoryQuery {
    from: Option<String>,
    to: Option<String>,
    limit: Option<usize>,
}

fn parse_instant(raw: &str) -> Result<i64, &'static str> {
    time::OffsetDateTime::parse(raw, &time::format_description::well_known::Rfc3339)
        .map(|value| value.unix_timestamp())
        .map_err(|_| "timestamps must be RFC 3339")
}

fn invalid_range(message: &str) -> (axum::http::StatusCode, Json<Value>) {
    (
        axum::http::StatusCode::BAD_REQUEST,
        Json(json!({
            "error": {
                "code": "INVALID_TIME_RANGE",
                "message": message,
                "request_id": uuid::Uuid::new_v4().to_string(),
            }
        })),
    )
}

fn history_envelope(
    state: &AppState,
    recording: bool,
    latest: Option<i64>,
    rows: Vec<spark_telemetry::HistoryRow>,
) -> Value {
    json!({
        "api_version": state.config.api_major,
        "node_id": state.identity.node_id(),
        "recording": recording,
        "latest_observed_at": latest.map(rfc3339),
        "retention": {
            "raw_seconds": spark_telemetry::DEFAULT_RAW_RETENTION_SECONDS,
            "aggregate_seconds": spark_telemetry::DEFAULT_AGGREGATE_RETENTION_SECONDS,
            "raw_bucket_seconds": spark_telemetry::RAW_BUCKET_SECONDS,
            "aggregate_bucket_seconds": spark_telemetry::MINUTE_BUCKET_SECONDS,
        },
        "rows": rows.into_iter().map(history_row).collect::<Vec<_>>(),
    })
}

fn rfc3339(unix_seconds: i64) -> String {
    time::OffsetDateTime::from_unix_timestamp(unix_seconds)
        .unwrap_or(time::OffsetDateTime::UNIX_EPOCH)
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_owned())
}

fn history_row(row: spark_telemetry::HistoryRow) -> Value {
    json!({
        "observed_at": row.observed_at,
        "resolution": row.resolution,
        "sample_count": row.sample_count,
        "cpu_utilisation": row.cpu_utilisation,
        "load_average_1m": row.load_average_1m,
        "memory_total_bytes": row.memory_total_bytes,
        "memory_available_bytes": row.memory_available_bytes,
        "memory_pressure": row.memory_pressure,
        "temperature_celsius": row.temperature_celsius,
        "accelerator_utilisation": row.accelerator_utilisation,
        "accelerator_memory_used_bytes": row.accelerator_memory_used_bytes,
        "accelerator_memory_total_bytes": row.accelerator_memory_total_bytes,
        "active_requests": row.active_requests,
        "queue_depth": row.queue_depth,
        "tokens_per_second": row.tokens_per_second,
        "time_to_first_token_ms": row.time_to_first_token_ms,
    })
}
