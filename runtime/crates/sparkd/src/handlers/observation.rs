use super::*;

/// Return only public node identity for unauthenticated reachability checks.
pub async fn health(State(state): State<AppState>) -> Json<Value> {
    Json(json!({
        "status": "ok",
        "api_version": state.config.api_major,
        "runtime_version": state.config.runtime_version,
        "node_id": state.identity.node_id(),
        "auth_protocols": crate::auth::AUTH_PROTOCOLS,
    }))
}

/// Return the full protected node identity.
pub async fn identity(State(state): State<AppState>) -> Json<Value> {
    Json(identity_value(
        &state.identity,
        &state.config.runtime_version,
        state.tls_fingerprint.as_deref(),
    ))
}

/// Distinguish the Ed25519 authority fingerprint from the TLS leaf fingerprint clients pin for transport.
pub(crate) fn identity_value(
    identity: &spark_core::identity::NodeIdentity,
    runtime_version: &str,
    tls_fingerprint: Option<&str>,
) -> Value {
    json!({
        "node_id": identity.node_id(),
        "cluster_id": null,
        "name": identity.public.node_name,
        "role": "standalone",
        "authority_fingerprint": identity.fingerprint(),
        "tls_fingerprint": tls_fingerprint,
        "runtime_version": runtime_version,
        "dgx_os_version": serde_json::Value::Null,
        "auth_protocols": crate::auth::AUTH_PROTOCOLS,
    })
}

/// Report system, inference and operation status using live guard pressure projected to the contract enum.
pub async fn status(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> HandlerResult<Json<Value>> {
    let mut system = state.telemetry.system();
    // Read cached accelerator telemetry off the async executor because system snapshots alone contain no GPU temperature.
    if system.temperature_celsius.is_none() {
        let monitor = state.telemetry.clone();
        system.temperature_celsius = tokio::task::spawn_blocking(move || monitor.hardware())
            .await
            .map(|hardware| hardware.accelerator.temperature_celsius)
            .unwrap_or(None);
    }
    let inference = match &state.engine.manager {
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
    // Prefer the guard's fresh sample so status endpoints agree on pressure.
    system.memory_pressure = crate::guard::observed_pressure(state.guard.as_ref(), &system);
    let remote_access = match &state.remote {
        Some(remote) => remote.configured_mode().map_err(|error| {
            tracing::error!(%error, "status could not read remote access state");
            internal_error()
        })?,
        None => "unavailable".to_owned(),
    };
    let worker_metrics = state.jobs.worker_metrics();
    let database = state.database.as_ref().ok_or_else(internal_error)?.clone();
    let failed_cutoff = state.clock.now() - time::Duration::hours(24);
    let operation_counts =
        tokio::task::spawn_blocking(move || operation_counts(&database.lock(), failed_cutoff))
            .await
            .map_err(|error| {
                tracing::error!(%error, "status operation worker failed");
                internal_error()
            })?
            .map_err(|error| {
                tracing::error!(%error, "status could not aggregate operation state");
                internal_error()
            })?;

    let thermal = crate::guard::thermal_projection(state.guard.as_ref());
    Ok(Json(json!({
        "api_version": state.config.api_major,
        "node": identity_value(
            &state.identity,
            &state.config.runtime_version,
            state.tls_fingerprint.as_deref(),
        ),
        "cluster": null,
        "connection": {
            "server_observed_transport": "unclassified",
            "access_authentication": principal.access_authentication.api_name(),
            "remote_access": remote_access,
        },
        "system": {
            "unified_memory_total_bytes": system.unified_memory_total_bytes,
            "unified_memory_available_bytes": system.unified_memory_available_bytes,
            "memory_pressure": system.memory_pressure.api_name(),
            "cpu_utilisation": system.cpu_utilisation,
            "load_average_1m": system.load_average_1m,
            "disk_free_bytes": system.disk_free_bytes,
            "temperature_celsius": system.temperature_celsius,
            "power_state": system.power_state,
            "uptime_seconds": system.uptime_seconds,
            "thermal_state": thermal["thermal_state"],
            "thermal_warning_celsius": thermal["thermal_warning_celsius"],
            "thermal_hot_celsius": thermal["thermal_hot_celsius"],
            "thermal_critical_celsius": thermal["thermal_critical_celsius"],
        },
        "inference": inference,
        "operations": {
            "active": operation_counts.0,
            "waiting_for_approval": operation_counts.1,
            "failed_last_24h": operation_counts.2,
            // Expose rejected-worker counts so executor saturation remains diagnosable.
            "workers": {
                "capacity": worker_metrics.capacity,
                "in_flight": worker_metrics.in_flight,
                "admitted_total": worker_metrics.admitted,
                "rejected_total": worker_metrics.rejected,
                "high_water_mark": worker_metrics.high_water_mark,
            },
        },
    })))
}

/// Report actual runtime capabilities from bounded live probes or explicit development-backend evidence.
pub async fn capabilities(State(state): State<AppState>) -> HandlerResult<Json<Value>> {
    let runtime = match &state.engine.manager {
        Some(manager) => {
            let manager = manager.clone();
            tokio::task::spawn_blocking(move || manager.container_runtime())
                .await
                .map_err(|error| {
                    tracing::error!(%error, "capabilities engine probe task failed");
                    internal_error()
                })?
        }
        None => crate::engine::ContainerRuntimeReport::new(
            "none",
            false,
            Some("engine service is not configured".into()),
        ),
    };
    let (signed_catalogue, unverified_import) = match &state.models {
        Some(inventory) => (
            !inventory.snapshot().recipes.is_empty(),
            inventory.snapshot().allow_unverified_import,
        ),
        None => (false, false),
    };
    let cluster_management = state
        .cluster_coordination
        .as_ref()
        .is_some_and(|service| service.management_available());
    let mut limits = serde_json::Map::new();
    let optional_services = state.privileged.is_some()
        && state.database.is_some()
        && state
            .optional_services_available
            .load(std::sync::atomic::Ordering::SeqCst)
        && crate::service_api::verified_open_webui_recipe(&state).is_ok();
    limits.insert("engine_backend".into(), json!(runtime.backend_kind));
    // §35.8: publish what the coordinator can form so the app disables an unsupported mutation by name.
    limits.insert(
        "cluster_maximum_supported_members".into(),
        json!(crate::cluster_coordination::MAXIMUM_SUPPORTED_MEMBERS),
    );
    limits.insert(
        "cluster_supported_topologies".into(),
        json!(crate::cluster_coordination::SUPPORTED_TOPOLOGIES),
    );
    limits.insert(
        "cluster_validated_member_counts".into(),
        json!(crate::cluster_coordination::VALIDATED_MEMBER_COUNTS),
    );
    // Larger member sets can be imported for inventory and telemetry, never formed or launched.
    limits.insert(
        "cluster_inventory_only_above_members".into(),
        json!(crate::cluster_coordination::MAXIMUM_SUPPORTED_MEMBERS),
    );
    limits.insert("max_active_large_models".into(), json!(1));
    limits.insert(
        "optional_service_inference_gateway_port".into(),
        json!(spark_privd::backend::OPEN_WEBUI_GATEWAY_PORT),
    );
    limits.insert(
        "optional_service_access_port".into(),
        json!(state.config.listen.port().checked_add(1)),
    );
    limits.insert(
        "optional_service_access_tls".into(),
        json!(state.config.tls),
    );
    limits.insert(
        "optional_service_listeners_available".into(),
        json!(
            state
                .optional_services_available
                .load(std::sync::atomic::Ordering::SeqCst)
        ),
    );
    limits.insert(
        "internal_port_range_start".into(),
        json!(crate::engine::INTERNAL_PORT_RANGE_START),
    );
    limits.insert(
        "internal_port_range_end".into(),
        json!(crate::engine::INTERNAL_PORT_RANGE_END),
    );
    if let Some(detail) = runtime.detail {
        limits.insert("container_runtime_detail".into(), json!(detail));
    }
    Ok(Json(json!({
        "api_version": state.config.api_major,
        "features": {
            "container_runtime": runtime.available,
            "loopback_only": true,
            "signed_catalogue": signed_catalogue,
            "signed_catalogue_refresh": state.catalogue_refresh.is_some(),
            "unverified_import": unverified_import,
            "cluster_management": cluster_management,
            "cluster_inference": crate::cluster_coordination::CLUSTER_INFERENCE_QUALIFIED,
            "fabric_inventory": true,
            "external_cluster_import_preview": state.database.is_some(),
            "external_cluster_registration": false,
            "fabric_takeover": false,
            "memory_guard": state.guard.is_some(),
            // Advertise unsafe-profile review only when both guard and verified catalogue can supply its evidence.
            "model_profile_reenable": state.guard.is_some() && state.models.is_some(),
            "live_telemetry": true,
            // Advertise durable analysis only when an engine and database are available to complete and retain its result.
            "durable_text_analysis": state.engine.manager.is_some() && state.database.is_some(),
            "inference_request_history": state.database.is_some(),
            "scheduled_warmup": state.database.is_some()
                && state.engine.manager.is_some()
                && state.models.is_some()
                && state.catalogue_refresh.is_some()
                && state.cluster.is_some(),
            "inference_pool_admission": state.database.is_some()
                && state.engine.manager.is_some()
                && state.models.is_some(),
            // Admission and a terminal node endpoint are not a multi-node router.
            "inference_pool_routing": false,
            "inference_pool_router_identity": state.database.is_some() && state.tls_fingerprint.is_some(),
            // Observe host workloads through the privileged boundary because sparkd cannot access the container runtime.
            "workload_inventory": state.privileged.is_some(),
            // Advertise adoption only when every required ownership-transaction service exists.
            "workload_adoption": crate::workload_api::ADOPTION_SUPPORTED
                && state.privileged.is_some()
                && state.engine.manager.is_some()
                && state.models.is_some(),
            "device_revocation_user_presence": true,
            "signed_runtime_update": true,
            "optional_service_recipes": optional_services,
            "open_webui_service": optional_services,
            "open_webui_ports": optional_services,
            "open_webui_owned_repair": optional_services,
            "projects": state.projects.manager.is_some()
                && state.database.is_some()
                && state.privileged.is_some(),
            "development_workspaces": state.projects.manager.is_some()
                && state.database.is_some() && state.privileged.is_some(),
            "development_prepare": state.projects.manager.is_some()
                && state.database.is_some() && state.privileged.is_some(),
            "project_agents": state.agents.execution_available,
        },
        "limits": Value::Object(limits),
    })))
}

pub(super) fn operation_counts(
    conn: &rusqlite::Connection,
    failed_cutoff: time::OffsetDateTime,
) -> Result<(i64, i64, i64), Box<dyn std::error::Error + Send + Sync>> {
    let active = conn.query_row(
        "SELECT COUNT(*) FROM operations INDEXED BY operations_state_idx
          WHERE state IN ('requested','validating','queued','running','cancelling')",
        [],
        |row| row.get(0),
    )?;
    let waiting_for_approval = conn.query_row(
        "SELECT COUNT(*) FROM operations INDEXED BY operations_state_idx
          WHERE state = 'waiting_for_approval'",
        [],
        |row| row.get(0),
    )?;

    // Use indexed candidates, then parse exact timestamps in Rust because SQLite unixepoch drops fractional seconds.
    let coarse_cutoff = (failed_cutoff - time::Duration::hours(1))
        .to_offset(time::UtcOffset::UTC)
        .format(&time::format_description::well_known::Rfc3339)?;
    let mut statement = conn.prepare(
        "SELECT completed_at FROM operations INDEXED BY operations_state_idx
          WHERE state = 'failed' AND updated_at >= ?1",
    )?;
    let rows = statement.query_map([coarse_cutoff], |row| row.get::<_, Option<String>>(0))?;
    let mut failed_last_24h = 0;
    for completed_at in rows {
        let completed_at = completed_at?.ok_or("failed operation has no completion timestamp")?;
        let completed_at = time::OffsetDateTime::parse(
            &completed_at,
            &time::format_description::well_known::Rfc3339,
        )?;
        if completed_at >= failed_cutoff {
            failed_last_24h += 1;
        }
    }

    Ok((active, waiting_for_approval, failed_last_24h))
}
