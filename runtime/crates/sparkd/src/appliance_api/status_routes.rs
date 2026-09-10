use super::*;

pub(super) fn observed_at(state: &AppState) -> String {
    state
        .clock
        .now()
        .format(&time::format_description::well_known::Rfc3339)
        .expect("UTC timestamps format as RFC3339")
}

pub(super) async fn hardware_snapshot(state: &AppState) -> HardwareSnapshot {
    let monitor = state.telemetry.clone();
    tokio::task::spawn_blocking(move || monitor.hardware())
        .await
        .unwrap_or_else(|error| {
            tracing::warn!(%error, "appliance hardware probe worker failed");
            HardwareSnapshot::default()
        })
}

pub async fn get_settings(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::NodeRead)
        .resource(SETTINGS_RESOURCE)
        .check()?;
    let timestamp = observed_at(&state);
    let mut host = state.appliance.host_settings(&timestamp).await;
    let accelerator = hardware_snapshot(&state).await.accelerator;
    host.power_profile.temperature_celsius = accelerator.temperature_celsius;
    host.power_profile.power_draw_watts = accelerator.power_draw_watts;
    host.power_profile.power_limit_watts = accelerator.power_limit_watts;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("settings database is unavailable"))?;
    let (memory, idle, telemetry) = {
        let connection = database.lock();
        (
            load_setting::<MemoryGuardConfig>(&connection, MEMORY_KEY)
                .map_err(|error| internal_envelope(&error.to_string()))?
                .unwrap_or_default(),
            load_idle_policies(&connection)
                .map_err(|error| internal_envelope(&error.to_string()))?,
            load_setting::<TelemetryConsentConfig>(&connection, TELEMETRY_KEY)
                .map_err(|error| internal_envelope(&error.to_string()))?
                .unwrap_or_default(),
        )
    };
    Ok(Json(json!({
        "api_version": state.config.api_major,
        "observed_at": timestamp,
        "direct_ethernet_enabled": host.direct_ethernet_enabled,
        "travel_access_point": host.travel_access_point,
        "bluetooth": host.bluetooth,
        "power_profile": host.power_profile,
        "software_updates": host.software_updates,
        "memory_guard": memory,
        "model_idle_policies": idle,
        "time": host.time,
        "telemetry_consent": telemetry,
    })))
}

pub async fn get_wifi_networks(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::NodeRead)
        .resource("wifi-networks")
        .check()?;
    Ok(Json(json!({
        "api_version": state.config.api_major,
        "observed_at": observed_at(&state),
        "networks": state.appliance.wifi_networks().await,
    })))
}

pub async fn get_software_updates(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::NodeRead)
        .resource(SETTINGS_RESOURCE)
        .check()?;
    let timestamp = observed_at(&state);
    let settings = state.appliance.host_settings(&timestamp).await;
    Ok(Json(json!(settings.software_updates)))
}

pub async fn get_storage(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::NodeRead)
        .resource("storage")
        .check()?;
    let models = state.storage.models.clone();
    let downloads = state.storage.downloads.clone();
    let blobs = state.config.data_dir.join("blobs");
    let (models_bytes, downloads_bytes, blobs_bytes) = tokio::task::spawn_blocking(move || {
        (
            directory_size(&models),
            directory_size(&downloads),
            directory_size(&blobs),
        )
    })
    .await
    .map_err(|error| internal_envelope(&error.to_string()))?;
    let (containers_bytes, container_reclaimable) = state.appliance.container_storage().await;
    let storage = hardware_snapshot(&state).await.storage;
    Ok(Json(json!({
        "observed_at": observed_at(&state),
        "total_bytes": storage.total_bytes,
        "free_bytes": storage.free_bytes,
        "models_bytes": models_bytes,
        "downloads_bytes": downloads_bytes,
        "blobs_bytes": blobs_bytes,
        "containers_bytes": containers_bytes,
        "reclaimable_bytes": container_reclaimable.saturating_add(partial_download_size(&state.storage.downloads)),
    })))
}
