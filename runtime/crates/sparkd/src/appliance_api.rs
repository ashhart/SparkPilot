//! Authorize and presence-gate durable appliance mutations; keep Wi-Fi credentials write-only and outside retained records.

use std::collections::{HashMap, HashSet};

use std::net::Ipv4Addr;

use std::path::{Path, PathBuf};

use std::sync::Arc;

use std::time::Duration;

use async_trait::async_trait;

use axum::Json;

use axum::extract::{Extension, Path as AxumPath, State};

use axum::http::{HeaderMap, StatusCode};

use base64::Engine as _;

use serde::de::DeserializeOwned;

use serde::{Deserialize, Serialize};

use serde_json::{Value, json};

use spark_privd::protocol::{BluetoothAction, PrivilegedOperation, SecretString};

use spark_telemetry::{HardwareSnapshot, MemoryPolicy};

use tokio::process::Command;

use tokio::time::timeout;

use uuid::Uuid;

use crate::auth::{AuthenticatedRequest, Principal};

use crate::capability::Capability;

use crate::idempotency::{IdempotencyRequest, json_response};

use crate::state::AppState;

const COMMAND_TIMEOUT: Duration = Duration::from_secs(12);

const SETTINGS_RESOURCE: &str = "appliance-settings";

const MEMORY_KEY: &str = "memory_guard";

const TELEMETRY_KEY: &str = "telemetry_consent";

/// Read the owner's stored web-access decision, or nothing when none has been made.
pub fn load_web_access(
    connection: &rusqlite::Connection,
) -> Result<Option<crate::automations_api::web_settings::StoredWebAccess>, rusqlite::Error> {
    load_setting(
        connection,
        crate::automations_api::web_settings::WEB_ACCESS_KEY,
    )
}

/// Write the owner's web-access decision through the shared appliance settings row.
pub fn store_web_access(
    connection: &rusqlite::Connection,
    value: &crate::automations_api::web_settings::StoredWebAccess,
    updated_at: &str,
    device_id: Uuid,
) -> Result<(), rusqlite::Error> {
    store_setting(
        connection,
        crate::automations_api::web_settings::WEB_ACCESS_KEY,
        value,
        updated_at,
        device_id,
    )
}

fn error_envelope(status: StatusCode, code: &str, message: &str) -> (StatusCode, Json<Value>) {
    (
        status,
        Json(json!({
            "error": {
                "code": code,
                "message": message,
                "request_id": crate::route::current_request_id(),
            }
        })),
    )
}

/// §58.4: carry structured, secret-free details so a client can name what it is waiting for.
fn detailed_error_envelope(
    status: StatusCode,
    code: &str,
    message: &str,
    details: Value,
) -> (StatusCode, Json<Value>) {
    (
        status,
        Json(json!({
            "error": {
                "code": code,
                "message": message,
                "request_id": crate::route::current_request_id(),
                "details": details,
            }
        })),
    )
}

fn internal_envelope(message: &str) -> (StatusCode, Json<Value>) {
    error_envelope(StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL", message)
}

async fn fixed_output(program: &str, arguments: &[&str]) -> Option<String> {
    fixed_output_with_status(program, arguments, &[0]).await
}

async fn fixed_output_with_status(
    program: &str,
    arguments: &[&str],
    accepted_statuses: &[i32],
) -> Option<String> {
    let mut command = Command::new(program);
    // Remove inherited sd_notify state because systemd accepts these notifications only from the main daemon PID.
    command
        .args(arguments)
        .env("LC_ALL", "C")
        .env_remove("NOTIFY_SOCKET");
    let output = timeout(COMMAND_TIMEOUT, command.output())
        .await
        .ok()?
        .ok()?;
    output
        .status
        .code()
        .is_some_and(|code| accepted_statuses.contains(&code))
        .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

impl From<BluetoothActionRequest> for BluetoothAction {
    fn from(value: BluetoothActionRequest) -> Self {
        match value {
            BluetoothActionRequest::PowerOn => Self::PowerOn,
            BluetoothActionRequest::PowerOff => Self::PowerOff,
            BluetoothActionRequest::StartDiscovery => Self::StartDiscovery,
            BluetoothActionRequest::StopDiscovery => Self::StopDiscovery,
            BluetoothActionRequest::Pair => Self::Pair,
            BluetoothActionRequest::Remove => Self::Remove,
        }
    }
}

#[cfg(test)]
mod runtime_update_failure_code_tests {
    use super::update_routes::runtime_update_failure_code;
    use spark_privd::protocol::PrivilegedResponse;
    use uuid::Uuid;

    #[test]
    fn the_helpers_update_reason_becomes_the_operation_code() {
        let response = PrivilegedResponse::rejected(
            Uuid::nil(),
            "backend_error",
            "UPDATE_STAGING_INVALID manifest.json is unusable: Permission denied (os error 13)",
        );
        assert_eq!(
            runtime_update_failure_code(&response),
            "UPDATE_STAGING_INVALID"
        );
    }

    #[test]
    fn a_refusal_without_an_update_reason_keeps_the_helpers_code() {
        let response = PrivilegedResponse::rejected(
            Uuid::nil(),
            "privileged_operation_busy",
            "another privileged operation is running",
        );
        assert_eq!(
            runtime_update_failure_code(&response),
            "privileged_operation_busy"
        );
    }
}

mod status_models;
pub use status_models::{
    ApplianceStatusProvider, BluetoothDeviceStatus, BluetoothStatus, HostSettingsStatus,
    PowerProfileMode, PowerProfileStatus, SoftwareUpdateStatus, SystemApplianceStatusProvider,
    SystemTimeStatus, TravelAccessPointStatus, WifiNetwork, default_appliance_status_provider,
};

mod settings_store;
pub use settings_store::{
    MemoryGuardConfig, ModelIdlePolicyConfig, TelemetryConsentConfig, persisted_memory_policy,
    persisted_telemetry_consent,
};
use settings_store::{load_idle_policies, load_setting, store_setting};

mod status_routes;
use status_routes::observed_at;
pub use status_routes::{get_settings, get_software_updates, get_storage, get_wifi_networks};

mod storage;
pub use storage::{StorageCleanupRequest, clean_storage};
use storage::{directory_size, partial_download_size};

mod network_observation;
use network_observation::{network_feature_status, wifi_scan};

mod host_observation;
use host_observation::{
    bluetooth_status, docker_storage, power_profile_status, software_update_status,
    system_time_status,
};

mod operation_admission;
use operation_admission::require_manage_role;
pub(crate) use operation_admission::{enqueue_operation, finish_privileged};

mod wifi_routes;
pub use wifi_routes::{
    ConfigureLanIpv4Request, ConnectWifiRequest, EnabledRequest, ForgetWifiRequest,
    TravelAccessPointRequest, configure_direct_ethernet, configure_lan_ipv4,
    configure_travel_access_point, connect_wifi, forget_wifi,
};

mod host_routes;
use host_routes::BluetoothActionRequest;
pub use host_routes::{
    ConfigureBluetoothRequest, ConfigureSystemTimeRequest, SetPowerProfileRequest,
    configure_bluetooth, configure_system_time, set_power_profile,
};

mod update_routes;
#[cfg(test)]
mod update_routes_lease_tests;
pub(crate) use update_routes::complete_runtime_update;
pub use update_routes::{
    InstallSoftwareUpdatesRequest, RuntimeReleaseBundleRequest, install_software_updates,
    refresh_software_updates,
};

mod network_recovery;
pub use network_recovery::{confirm_network_change, rollback_network_change};

mod policy_routes;
pub use policy_routes::{update_memory_guard, update_model_idle_policy, update_telemetry_consent};
