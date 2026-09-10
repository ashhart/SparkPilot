use super::*;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectWifiRequest {
    ssid: String,
    passphrase: Option<String>,
    #[serde(default)]
    hidden: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ForgetWifiRequest {
    ssid: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConfigureLanIpv4Request {
    address: Ipv4Addr,
    prefix_length: u8,
    gateway: Ipv4Addr,
    dns_servers: Vec<Ipv4Addr>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnabledRequest {
    enabled: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TravelAccessPointRequest {
    enabled: bool,
    ssid: Option<String>,
    passphrase: Option<String>,
}

pub async fn connect_wifi(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<ConnectWifiRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    require_manage_role(
        &state,
        &principal,
        &idempotency,
        "/api/v1/network/wifi",
        "network.wifi.connect",
    )?;
    if !valid_ssid(&request.ssid)
        || request
            .passphrase
            .as_deref()
            .is_some_and(|value| !valid_wifi_passphrase(value, 8))
    {
        return Err(error_envelope(
            StatusCode::BAD_REQUEST,
            "INVALID_WIFI_CREDENTIALS",
            "the Wi-Fi name or password does not meet the network policy",
        ));
    }
    let privileged = state.privileged.clone().ok_or_else(|| {
        error_envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "NETWORK_SERVICE_UNAVAILABLE",
            "Wi-Fi management is unavailable",
        )
    })?;
    let ssid = request.ssid;
    let hidden = request.hidden;
    let passphrase = request.passphrase.map(SecretString::new);
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/network/wifi",
        "network.wifi.connect",
        json!({ "ssid": ssid, "hidden": hidden, "protected_input_supplied": passphrase.is_some() }),
        None,
        move |operation_id, lease| {
            let result = privileged.call(PrivilegedOperation::ConnectWifi {
                request_id: operation_id,
                ssid: ssid.clone(),
                passphrase,
                hidden,
            });
            finish_privileged(
                lease,
                result,
                json!({ "ssid": ssid, "configuration_id": operation_id }),
                "NETWORK_CHANGE_FAILED",
            );
        },
    )
    .await
}

pub async fn forget_wifi(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<ForgetWifiRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    require_manage_role(
        &state,
        &principal,
        &idempotency,
        "/api/v1/network/wifi/forget",
        "network.wifi.forget",
    )?;
    if !valid_ssid(&request.ssid) {
        return Err(error_envelope(
            StatusCode::BAD_REQUEST,
            "INVALID_WIFI_SSID",
            "the Wi-Fi name is invalid",
        ));
    }
    let privileged = state.privileged.clone().ok_or_else(|| {
        error_envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "NETWORK_SERVICE_UNAVAILABLE",
            "Wi-Fi management is unavailable",
        )
    })?;
    let ssid = request.ssid;
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/network/wifi/forget",
        "network.wifi.forget",
        json!({ "ssid": ssid }),
        None,
        move |operation_id, lease| {
            let result = privileged.call(PrivilegedOperation::ForgetWifi {
                request_id: operation_id,
                ssid: ssid.clone(),
            });
            finish_privileged(
                lease,
                result,
                json!({ "ssid": ssid }),
                "NETWORK_CHANGE_FAILED",
            );
        },
    )
    .await
}

pub async fn configure_lan_ipv4(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<ConfigureLanIpv4Request>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    require_manage_role(
        &state,
        &principal,
        &idempotency,
        "/api/v1/network/ethernet/ipv4",
        "network.lan.ipv4",
    )?;
    if !spark_privd::protocol::valid_lan_ipv4(
        request.address,
        request.prefix_length,
        request.gateway,
        &request.dns_servers,
    ) {
        return Err(error_envelope(
            StatusCode::BAD_REQUEST,
            "INVALID_STATIC_IPV4",
            "the manual IPv4 address, gateway, or DNS values are unsafe",
        ));
    }
    let privileged = state.privileged.clone().ok_or_else(|| {
        error_envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "NETWORK_SERVICE_UNAVAILABLE",
            "manual LAN configuration is unavailable",
        )
    })?;
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/network/ethernet/ipv4",
        "network.lan.ipv4",
        json!({
            "address": request.address,
            "prefix_length": request.prefix_length,
            "gateway": request.gateway,
            "dns_servers": &request.dns_servers,
            "auto_revert_seconds": 30,
        }),
        None,
        move |operation_id, lease| {
            let result = privileged.call(PrivilegedOperation::ConfigureLanIpv4 {
                request_id: operation_id,
                configuration_id: operation_id,
                address: request.address,
                prefix_length: request.prefix_length,
                gateway: request.gateway,
                dns_servers: request.dns_servers.clone(),
            });
            finish_privileged(
                lease,
                result,
                json!({
                    "configuration_id": operation_id,
                    "candidate_address": format!("{}/{}", request.address, request.prefix_length),
                    "auto_revert_seconds": 30,
                }),
                "NETWORK_CHANGE_FAILED",
            );
        },
    )
    .await
}

pub async fn configure_direct_ethernet(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<EnabledRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    require_manage_role(
        &state,
        &principal,
        &idempotency,
        "/api/v1/network/direct-profile",
        "network.direct_ethernet",
    )?;
    let privileged = state.privileged.clone().ok_or_else(|| {
        error_envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "NETWORK_SERVICE_UNAVAILABLE",
            "direct Ethernet management is unavailable",
        )
    })?;
    let enabled = request.enabled;
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/network/direct-profile",
        "network.direct_ethernet",
        json!({ "enabled": enabled }),
        None,
        move |operation_id, lease| {
            let result = privileged.call(PrivilegedOperation::ConfigureDirectEthernet {
                request_id: operation_id,
                enabled,
            });
            finish_privileged(
                lease,
                result,
                json!({ "enabled": enabled, "configuration_id": operation_id }),
                "NETWORK_CHANGE_FAILED",
            );
        },
    )
    .await
}

pub async fn configure_travel_access_point(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<TravelAccessPointRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    require_manage_role(
        &state,
        &principal,
        &idempotency,
        "/api/v1/network/travel-ap",
        "network.travel_access_point",
    )?;
    if request.enabled
        && (!request.ssid.as_deref().is_some_and(valid_ssid)
            || !request
                .passphrase
                .as_deref()
                .is_some_and(|value| valid_wifi_passphrase(value, 12)))
    {
        return Err(error_envelope(
            StatusCode::BAD_REQUEST,
            "INVALID_TRAVEL_ACCESS_POINT",
            "travel mode needs a valid Wi-Fi name and a 12 to 63 character password",
        ));
    }
    let privileged = state.privileged.clone().ok_or_else(|| {
        error_envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "NETWORK_SERVICE_UNAVAILABLE",
            "travel access-point management is unavailable",
        )
    })?;
    let enabled = request.enabled;
    let ssid = request.ssid;
    let passphrase = request.passphrase.map(SecretString::new);
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/network/travel-ap",
        "network.travel_access_point",
        json!({
            "enabled": enabled,
            "ssid": ssid,
            "protected_input_supplied": passphrase.is_some(),
            "auto_revert_seconds": 90,
        }),
        None,
        move |operation_id, lease| {
            let result = privileged.call(PrivilegedOperation::ConfigureTravelAccessPoint {
                request_id: operation_id,
                configuration_id: operation_id,
                enabled,
                ssid: ssid.clone(),
                passphrase,
            });
            finish_privileged(
                lease,
                result,
                json!({ "enabled": enabled, "ssid": ssid, "configuration_id": operation_id }),
                "NETWORK_CHANGE_FAILED",
            );
        },
    )
    .await
}

pub(super) fn valid_ssid(value: &str) -> bool {
    (1..=32).contains(&value.len()) && !value.chars().any(char::is_control)
}

pub(super) fn valid_wifi_passphrase(value: &str, minimum: usize) -> bool {
    (minimum..=63).contains(&value.len())
        && value.is_ascii()
        && !value.chars().any(char::is_control)
}
