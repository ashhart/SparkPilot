use super::*;

/// Read only selected distribution fields from this fixed world-readable file.
pub(super) const OS_RELEASE_PATH: &str = "/etc/os-release";

/// Read the fixed world-readable driver-version file without invoking privileged or external tools.
pub(super) const NVIDIA_VERSION_PATH: &str = spark_core::NVIDIA_DRIVER_VERSION_PATH;

pub(in super::super) fn runtime_section(state: &AppState) -> Value {
    // Select configuration fields explicitly so adding a secret cannot add it to exports.
    json!({
        "available": true,
        "runtime_version": state.config.runtime_version,
        "api_major": state.config.api_major,
        "tls": state.config.tls,
        "advertises_on_bonjour": state.config.advertise,
        "listen_port": state.config.listen.port(),
    })
}

/// Parse only two os-release keys so future identifying fields cannot widen the bundle.
pub(super) fn os_release() -> Value {
    let Ok(text) = std::fs::read_to_string(OS_RELEASE_PATH) else {
        return unavailable_code(OS_RELEASE_UNREADABLE);
    };
    let mut pretty_name = None;
    let mut version_id = None;
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        // Constrain selected release names to short printable tokens.
        let Some(value) = release_token(value.trim_matches('"')) else {
            continue;
        };
        match key {
            "PRETTY_NAME" => pretty_name = Some(value),
            "VERSION_ID" => version_id = Some(value),
            _ => {}
        }
    }
    json!({ "available": true, "pretty_name": pretty_name, "version_id": version_id })
}

/// Extract only the token after Kernel Module; unfamiliar banners yield no driver version.
pub(super) fn nvidia_driver_version() -> Value {
    let Ok(text) = std::fs::read_to_string(NVIDIA_VERSION_PATH) else {
        return unavailable_code(DRIVER_VERSION_UNREADABLE);
    };
    let version = spark_core::nvidia_kernel_module_version(&text).map(str::to_owned);
    match version {
        Some(version) => json!({ "available": true, "kernel_module_version": version }),
        None => unavailable_code(DRIVER_VERSION_UNREADABLE),
    }
}

pub(in super::super) fn host_section(state: &AppState) -> Value {
    let system = state.telemetry.system();
    let hardware = state.telemetry.hardware();
    let runtime = state
        .engine
        .manager
        .as_ref()
        .map(|manager| manager.container_runtime());
    json!({
        "available": true,
        "os": os_release(),
        "driver": nvidia_driver_version(),
        // Keep fixed outcomes while dropping free-text details that may disclose paths or banners.
        "container_runtime": match &runtime {
            Some(report) => json!({
                "available": report.available,
                "backend": report.backend_kind,
                "gpu_runtime": report.gpu_runtime,
                "detail_present": report.detail.is_some(),
            }),
            None => unavailable_code(NO_PRIVILEGED_BOUNDARY),
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
            "total_bytes": hardware.storage.total_bytes,
            "free_bytes": hardware.storage.free_bytes,
        },
        "unified_memory_total_bytes": system.unified_memory_total_bytes,
        "unified_memory_available_bytes": system.unified_memory_available_bytes,
        "memory_pressure": system.memory_pressure.api_name(),
        "memory_psi_some_avg10": hardware.memory_psi_some_avg10,
        "memory_psi_full_avg10": hardware.memory_psi_full_avg10,
        "cpu_utilisation": system.cpu_utilisation,
        "load_average_1m": system.load_average_1m,
        "disk_free_bytes": system.disk_free_bytes,
        "temperature_celsius": system.temperature_celsius,
        "power_state": allowlisted(Some(&json!(system.power_state)), POWER_STATES),
        "uptime_seconds": system.uptime_seconds,
    })
}

pub(in super::super) fn services_section(state: &AppState) -> Value {
    // Report observed engine health rather than merely the existence of a service object.
    let engine = match state.engine.manager.as_ref() {
        Some(manager) => match manager.view() {
            Some(view) => json!({
                "state": view.state.as_str(),
                "model_id": view.model_id,
                "profile_id": view.profile_id,
                "active_requests": view.active_requests,
                "adopted_external_workload": view.external_workload_id.is_some(),
            }),
            None => json!({ "state": "unloaded" }),
        },
        None => unavailable_code(NO_PRIVILEGED_BOUNDARY),
    };
    let guard = match state.guard.as_ref() {
        Some(guard) => {
            let reading = guard.reading();
            json!({
                "pressure": reading.state.as_str(),
                "available_bytes": reading.available_bytes,
            })
        }
        None => json!({ "available": false, "reason_code": "GUARD_NOT_COMPOSED" }),
    };
    let cluster = match state.cluster.as_ref().and_then(|c| c.status().ok()) {
        Some(status) => json!({ "state": status.state, "members": status.members.len() }),
        None => json!({ "state": "standalone" }),
    };
    // Export remote posture without hostname, tunnel ID or secret reference.
    let remote = read_row(
        state,
        "SELECT enabled, mode, health FROM remote_access WHERE singleton = 1",
        |row| {
            Ok(json!({
                "enabled": row.get::<_, i64>(0)? != 0,
                "mode": allowlisted(Some(&json!(row.get::<_, String>(1)?)), REMOTE_MODES),
                "health": allowlisted(Some(&json!(row.get::<_, String>(2)?)), REMOTE_HEALTH),
            }))
        },
    )
    .unwrap_or_else(|| json!({ "enabled": false, "mode": "disabled" }));

    json!({
        "available": true,
        "engine": engine,
        "memory_guard": guard,
        "cluster": cluster,
        "remote_access": remote,
        "optional_service_listeners_available": state
            .optional_services_available
            .load(std::sync::atomic::Ordering::SeqCst),
    })
}

pub(in super::super) async fn network_section(state: &AppState, full_addresses: bool) -> Value {
    let checked_at = state.clock.now_rfc3339();
    let Ok(interfaces) = state.network_status.interfaces(&checked_at).await else {
        return unavailable_code(NETWORK_INVENTORY_UNAVAILABLE);
    };
    let rendered: Vec<Value> = interfaces
        .iter()
        .map(|interface| {
            let mut entry = json!({
                "name": interface.name,
                "type": interface.interface_type,
                "state": interface.state,
                "mtu": interface.mtu,
                "link_speed_mbps": interface.link_speed_mbps,
                "address_count": interface.addresses.len(),
            });
            let object = entry.as_object_mut().expect("object");
            if full_addresses {
                object.insert(
                    "addresses".into(),
                    json!(
                        interface
                            .addresses
                            .iter()
                            .map(|address| json!({
                                "family": address.family,
                                "address": address.address,
                            }))
                            .collect::<Vec<_>>()
                    ),
                );
                object.insert("gateway".into(), json!(interface.gateway));
                object.insert("dns_servers".into(), json!(interface.dns_servers));
                object.insert("mac_address".into(), json!(interface.mac_address));
                object.insert("wifi_ssid".into(), json!(interface.wifi_ssid));
            } else {
                // Report address family and prefix length while reserving identifying network addresses for owner-selected export.
                object.insert(
                    "addresses".into(),
                    json!(
                        interface
                            .addresses
                            .iter()
                            .map(|address| json!({ "family": address.family }))
                            .collect::<Vec<_>>()
                    ),
                );
            }
            entry
        })
        .collect();
    json!({ "available": true, "checked_at": checked_at, "interfaces": rendered })
}

pub(in super::super) fn host_paths_section(state: &AppState) -> Value {
    json!({
        "available": true,
        "data_dir": state.config.data_dir.display().to_string(),
        "models_dir": state.storage.models.display().to_string(),
        "downloads_dir": state.storage.downloads.display().to_string(),
    })
}
