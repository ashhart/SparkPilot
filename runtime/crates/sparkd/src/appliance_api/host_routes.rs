use super::*;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum BluetoothActionRequest {
    PowerOn,
    PowerOff,
    StartDiscovery,
    StopDiscovery,
    Pair,
    Remove,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConfigureBluetoothRequest {
    action: BluetoothActionRequest,
    device_address: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetPowerProfileRequest {
    mode_id: u8,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConfigureSystemTimeRequest {
    timezone: String,
    ntp_enabled: bool,
}

pub async fn configure_bluetooth(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<ConfigureBluetoothRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let privileged = state.privileged.clone().ok_or_else(|| {
        error_envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "BLUETOOTH_UNAVAILABLE",
            "Bluetooth management is unavailable",
        )
    })?;
    let action = BluetoothAction::from(request.action);
    let address = request.device_address;
    let action_name = match action {
        BluetoothAction::PowerOn => "power_on",
        BluetoothAction::PowerOff => "power_off",
        BluetoothAction::StartDiscovery => "start_discovery",
        BluetoothAction::StopDiscovery => "stop_discovery",
        BluetoothAction::Pair => "pair",
        BluetoothAction::Remove => "remove",
    };
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/system/bluetooth",
        "system.bluetooth",
        json!({ "action": action_name, "device_address": address }),
        None,
        move |operation_id, lease| {
            let result = privileged.call(PrivilegedOperation::ConfigureBluetooth {
                request_id: operation_id,
                action,
                device_address: address.clone(),
            });
            finish_privileged(
                lease,
                result,
                json!({ "action": action_name, "device_address": address }),
                "BLUETOOTH_CHANGE_FAILED",
            );
        },
    )
    .await
}

pub async fn set_power_profile(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<SetPowerProfileRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let privileged = state.privileged.clone().ok_or_else(|| {
        error_envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "POWER_PROFILE_UNAVAILABLE",
            "power-profile management is unavailable",
        )
    })?;
    let mode_id = request.mode_id;
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/system/power-profile",
        "system.power_profile",
        json!({ "mode_id": mode_id }),
        None,
        move |operation_id, lease| {
            let result = privileged.call(PrivilegedOperation::SetPowerProfile {
                request_id: operation_id,
                mode_id,
            });
            finish_privileged(
                lease,
                result,
                json!({ "mode_id": mode_id }),
                "POWER_PROFILE_CHANGE_FAILED",
            );
        },
    )
    .await
}

pub async fn configure_system_time(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<ConfigureSystemTimeRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    if !valid_timezone(&request.timezone) {
        return Err(error_envelope(
            StatusCode::BAD_REQUEST,
            "INVALID_TIMEZONE",
            "select a valid Area/Location timezone",
        ));
    }
    let privileged = state.privileged.clone().ok_or_else(|| {
        error_envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "TIME_SERVICE_UNAVAILABLE",
            "time configuration is unavailable",
        )
    })?;
    let timezone = request.timezone;
    let ntp_enabled = request.ntp_enabled;
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/system/time",
        "system.time",
        json!({ "timezone": timezone, "ntp_enabled": ntp_enabled }),
        None,
        move |operation_id, lease| {
            let result = privileged.call(PrivilegedOperation::ConfigureSystemTime {
                request_id: operation_id,
                timezone: timezone.clone(),
                ntp_enabled,
            });
            finish_privileged(
                lease,
                result,
                json!({ "timezone": timezone, "ntp_enabled": ntp_enabled }),
                "TIME_CONFIGURATION_FAILED",
            );
        },
    )
    .await
}

pub(super) fn valid_timezone(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.contains('/')
        && value.split('/').all(|component| {
            !component.is_empty()
                && component != "."
                && component != ".."
                && component.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-')
                })
        })
}
