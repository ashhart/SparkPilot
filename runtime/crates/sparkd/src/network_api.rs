//! Read signed NetworkManager state with bounded gateway and link-DNS probes, without profile mutations or privileged operations.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use axum::Json;
use axum::extract::{Extension, State};
use axum::http::StatusCode;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::process::Command;
use tokio::time::timeout;

use crate::auth::Principal;
use crate::capability::Capability;
use crate::state::AppState;

const COMMAND_TIMEOUT: Duration = Duration::from_secs(4);
const PROBE_HOST: &str = "example.com";

#[derive(Debug, thiserror::Error)]
pub enum NetworkStatusError {
    #[error("NetworkManager command could not start: {0}")]
    Command(#[from] std::io::Error),
    #[error("NetworkManager query timed out")]
    Timeout,
    #[error("NetworkManager query failed: {0}")]
    Query(String),
    #[error("NetworkManager returned no device records")]
    Empty,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct NetworkAddress {
    pub family: String,
    pub address: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InternetReachability {
    pub reachable: bool,
    pub gateway_reachable: Option<bool>,
    pub dns_reachable: Option<bool>,
    pub checked_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct NetworkInterfaceStatus {
    pub name: String,
    #[serde(rename = "type")]
    pub interface_type: String,
    pub state: String,
    pub connection_name: Option<String>,
    pub mac_address: Option<String>,
    pub mtu: Option<u64>,
    pub link_speed_mbps: Option<u64>,
    pub addresses: Vec<NetworkAddress>,
    pub gateway: Option<String>,
    pub dns_servers: Vec<String>,
    pub wifi_ssid: Option<String>,
    pub wifi_signal_percent: Option<u8>,
    pub internet: InternetReachability,
}

impl NetworkInterfaceStatus {
    /// Keep hardware and routing identifiers with administrators; link state and addresses remain.
    pub fn redacted(mut self) -> Self {
        self.mac_address = None;
        self.gateway = None;
        self.dns_servers.clear();
        self
    }
}

#[async_trait]
pub trait NetworkStatusProvider: Send + Sync {
    async fn interfaces(
        &self,
        checked_at: &str,
    ) -> Result<Vec<NetworkInterfaceStatus>, NetworkStatusError>;
}

#[derive(Debug, Default)]
pub struct NetworkManagerStatusProvider;

#[derive(Debug, Default)]
struct InterfaceBuilder {
    name: String,
    interface_type: String,
    state: String,
    connection_name: Option<String>,
    mac_address: Option<String>,
    mtu: Option<u64>,
    addresses: Vec<NetworkAddress>,
    gateway: Option<String>,
    dns_servers: Vec<String>,
}

#[async_trait]
impl NetworkStatusProvider for NetworkManagerStatusProvider {
    async fn interfaces(
        &self,
        checked_at: &str,
    ) -> Result<Vec<NetworkInterfaceStatus>, NetworkStatusError> {
        let output = command_output(
            "nmcli",
            &[
                "--terse",
                "--escape",
                "yes",
                "--fields",
                "GENERAL,IP4,IP6",
                "device",
                "show",
            ],
        )
        .await?;
        let builders = parse_device_show(&output)?;
        let checks = builders
            .into_iter()
            .map(|builder| enrich_interface(builder, checked_at.to_owned()));
        Ok(futures::future::join_all(checks).await)
    }
}

pub fn default_network_status_provider() -> Arc<dyn NetworkStatusProvider> {
    Arc::new(NetworkManagerStatusProvider)
}

pub async fn get_interfaces(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    // Every paired device may read link state; MACs, gateways and DNS servers are redacted below administrator.
    state
        .require(&principal, Capability::NodeRead)
        .resource("network")
        .check()?;
    let observed_at = state
        .clock
        .now()
        .format(&time::format_description::well_known::Rfc3339)
        .expect("UTC timestamps format as RFC3339");
    let interfaces = state
        .network_status
        .interfaces(&observed_at)
        .await
        .map_err(|error| {
            tracing::warn!(%error, "network status query failed");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({
                    "error": {
                        "code": "NETWORK_STATUS_UNAVAILABLE",
                        "message": "Network status is unavailable on this Spark.",
                        "request_id": crate::route::current_request_id(),
                    }
                })),
            )
        })?;
    let interfaces: Vec<NetworkInterfaceStatus> = if principal.is_admin() {
        interfaces
    } else {
        interfaces
            .into_iter()
            .map(NetworkInterfaceStatus::redacted)
            .collect()
    };
    Ok(Json(json!({
        "api_version": state.config.api_major,
        "observed_at": observed_at,
        "interfaces": interfaces,
    })))
}

fn internal_envelope(detail: &str) -> (StatusCode, Json<Value>) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({
            "error": { "code": "INTERNAL", "message": detail, "request_id": crate::route::current_request_id() }
        })),
    )
}

pub async fn get_network_status(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::NodeRead)
        .resource("network")
        .check()?;
    let Some(network) = &state.network else {
        return Err(internal_envelope("network service unavailable"));
    };
    let status = network
        .status()
        .map_err(|error| internal_envelope(&error))?;
    Ok(Json(serde_json::to_value(status).unwrap()))
}

async fn command_output(program: &str, arguments: &[&str]) -> Result<String, NetworkStatusError> {
    let mut command = Command::new(program);
    command.args(arguments).env("LC_ALL", "C");
    let output = timeout(COMMAND_TIMEOUT, command.output())
        .await
        .map_err(|_| NetworkStatusError::Timeout)??;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return Err(NetworkStatusError::Query(if detail.is_empty() {
            format!("{program} exited with {}", output.status)
        } else {
            detail
        }));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// What a gateway probe could tell us.
enum GatewayProbe {
    Reachable,
    Unreachable,
    /// The probe could not run at all, so it reports nothing.
    NotProbed,
}

/// Distinguish unanswered ping from inability to probe when daemon sandboxing prevents acquiring CAP_NET_RAW.
async fn probe_gateway(interface: &str, gateway: &str) -> GatewayProbe {
    let output = tokio::process::Command::new("ping")
        .args(["-n", "-I", interface, "-c", "1", "-W", "1", gateway])
        .output()
        .await;
    let Ok(output) = output else {
        return GatewayProbe::NotProbed;
    };
    if output.status.success() {
        return GatewayProbe::Reachable;
    }
    let complaint = String::from_utf8_lossy(&output.stderr).to_ascii_lowercase();
    let refused_to_run = complaint.contains("operation not permitted")
        || complaint.contains("permission denied")
        || complaint.contains("socket")
        || output.status.code().is_none_or(|code| code > 1);
    if refused_to_run {
        GatewayProbe::NotProbed
    } else {
        GatewayProbe::Unreachable
    }
}

async fn command_succeeds(program: &str, arguments: &[&str]) -> bool {
    command_output(program, arguments).await.is_ok()
}

fn parse_device_show(output: &str) -> Result<Vec<InterfaceBuilder>, NetworkStatusError> {
    let mut records = Vec::new();
    let mut current: Option<InterfaceBuilder> = None;
    for line in output.lines().filter(|line| !line.trim().is_empty()) {
        let Some((key, raw_value)) = split_nmcli_field(line) else {
            continue;
        };
        let value = unescape_nmcli(raw_value);
        if key == "GENERAL.DEVICE" {
            if let Some(record) = current.take() {
                records.push(record);
            }
            current = Some(InterfaceBuilder {
                name: value,
                ..InterfaceBuilder::default()
            });
            continue;
        }
        let Some(record) = current.as_mut() else {
            continue;
        };
        match key {
            "GENERAL.TYPE" => record.interface_type = normalise_type(&value),
            "GENERAL.STATE" => record.state = normalise_state(&value),
            "GENERAL.CONNECTION" if value != "--" => record.connection_name = Some(value),
            "GENERAL.HWADDR" if value != "--" => record.mac_address = Some(value),
            "GENERAL.MTU" => record.mtu = value.parse().ok(),
            "IP4.GATEWAY" | "IP6.GATEWAY" if record.gateway.is_none() && value != "--" => {
                record.gateway = Some(value)
            }
            key if key.starts_with("IP4.ADDRESS") => record.addresses.push(NetworkAddress {
                family: "ipv4".to_owned(),
                address: value,
            }),
            key if key.starts_with("IP6.ADDRESS") => record.addresses.push(NetworkAddress {
                family: "ipv6".to_owned(),
                address: value,
            }),
            key if key.starts_with("IP4.DNS") || key.starts_with("IP6.DNS") => {
                if !value.is_empty() && value != "--" && !record.dns_servers.contains(&value) {
                    record.dns_servers.push(value);
                }
            }
            _ => {}
        }
    }
    if let Some(record) = current {
        records.push(record);
    }
    records.retain(|record| !record.name.is_empty());
    if records.is_empty() {
        return Err(NetworkStatusError::Empty);
    }
    Ok(records)
}

async fn enrich_interface(builder: InterfaceBuilder, checked_at: String) -> NetworkInterfaceStatus {
    let connected = builder.state == "connected";
    let speed = link_speed_mbps(&builder.name).await;
    let (wifi_ssid, wifi_signal_percent) = if builder.interface_type == "wifi" {
        active_wifi(&builder.name).await
    } else {
        (None, None)
    };
    let (gateway_reachable, dns_reachable) = if connected {
        let gateway_probe = async {
            let gateway = builder.gateway.as_deref()?;
            // Report prohibited ICMP as unprobed, not unreachable; NoNewPrivileges and capability bounds can prevent ping from running.
            match probe_gateway(&builder.name, gateway).await {
                GatewayProbe::Reachable => Some(true),
                GatewayProbe::Unreachable => Some(false),
                GatewayProbe::NotProbed => None,
            }
        };
        let dns_probe = async {
            if builder.dns_servers.is_empty() {
                return None;
            }
            Some(
                command_succeeds(
                    "resolvectl",
                    &[
                        "query",
                        "--interface",
                        &builder.name,
                        "--legend=no",
                        "--cache=no",
                        PROBE_HOST,
                    ],
                )
                .await,
            )
        };
        tokio::join!(gateway_probe, dns_probe)
    } else {
        (None, None)
    };
    // Successful interface DNS proves external reachability even when gateway probing is unavailable.
    let reachable = connected && dns_reachable == Some(true) && gateway_reachable != Some(false);
    NetworkInterfaceStatus {
        name: builder.name,
        interface_type: builder.interface_type,
        state: builder.state,
        connection_name: builder.connection_name,
        mac_address: builder.mac_address,
        mtu: builder.mtu,
        link_speed_mbps: speed,
        addresses: builder.addresses,
        gateway: builder.gateway,
        dns_servers: builder.dns_servers,
        wifi_ssid,
        wifi_signal_percent,
        internet: InternetReachability {
            reachable,
            gateway_reachable,
            dns_reachable,
            checked_at,
        },
    }
}

async fn link_speed_mbps(interface: &str) -> Option<u64> {
    if !safe_interface_name(interface) {
        return None;
    }
    let path = Path::new("/sys/class/net").join(interface).join("speed");
    let value = tokio::fs::read_to_string(path).await.ok()?;
    value.trim().parse::<u64>().ok().filter(|speed| *speed > 0)
}

async fn active_wifi(interface: &str) -> (Option<String>, Option<u8>) {
    if !safe_interface_name(interface) {
        return (None, None);
    }
    let output = command_output(
        "nmcli",
        &[
            "--terse",
            "--escape",
            "yes",
            "--fields",
            "IN-USE,SSID,SIGNAL",
            "device",
            "wifi",
            "list",
            "ifname",
            interface,
            "--rescan",
            "no",
        ],
    )
    .await;
    let Ok(output) = output else {
        return (None, None);
    };
    output
        .lines()
        .filter_map(split_nmcli_row)
        .find_map(|fields| {
            if fields.len() != 3 || fields[0] != "*" {
                return None;
            }
            Some((
                (!fields[1].is_empty()).then(|| fields[1].clone()),
                fields[2].parse::<u8>().ok().map(|signal| signal.min(100)),
            ))
        })
        .unwrap_or((None, None))
}

fn safe_interface_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
}

fn split_nmcli_field(line: &str) -> Option<(&str, &str)> {
    let mut escaped = false;
    for (index, character) in line.char_indices() {
        if escaped {
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else if character == ':' {
            return Some((&line[..index], &line[index + 1..]));
        }
    }
    None
}

fn split_nmcli_row(line: &str) -> Option<Vec<String>> {
    let mut fields = Vec::new();
    let mut current = String::new();
    let mut escaped = false;
    for character in line.chars() {
        if escaped {
            current.push(character);
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else if character == ':' {
            fields.push(std::mem::take(&mut current));
        } else {
            current.push(character);
        }
    }
    if escaped {
        current.push('\\');
    }
    fields.push(current);
    Some(fields)
}

fn unescape_nmcli(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut escaped = false;
    for character in value.chars() {
        if escaped {
            result.push(character);
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else {
            result.push(character);
        }
    }
    if escaped {
        result.push('\\');
    }
    result
}

fn normalise_type(value: &str) -> String {
    match value {
        "802-3-ethernet" | "ethernet" => "ethernet",
        "802-11-wireless" | "wifi" => "wifi",
        "loopback" => "loopback",
        "bridge" => "bridge",
        _ => "other",
    }
    .to_owned()
}

fn normalise_state(value: &str) -> String {
    let value = value.to_ascii_lowercase();
    if value.contains("disconnected") {
        "disconnected"
    } else if value.contains("connected") {
        "connected"
    } else if value.contains("unavailable") || value.contains("unmanaged") {
        "unavailable"
    } else {
        "unknown"
    }
    .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEVICE_SHOW: &str = r"GENERAL.DEVICE:enp1s0
GENERAL.TYPE:ethernet
GENERAL.STATE:100 (connected)
GENERAL.CONNECTION:Wired connection 1
GENERAL.HWADDR:02\:00\:00\:00\:00\:42
GENERAL.MTU:1500
IP4.ADDRESS[1]:192.168.100.63/24
IP4.GATEWAY:192.168.100.1
IP4.DNS[1]:192.168.100.1
GENERAL.DEVICE:wlan0
GENERAL.TYPE:wifi
GENERAL.STATE:30 (disconnected)
GENERAL.CONNECTION:--
GENERAL.HWADDR:AA\:BB\:CC\:DD\:EE\:FF
GENERAL.MTU:1500
";

    #[test]
    fn network_manager_records_preserve_every_interface() {
        let records = parse_device_show(DEVICE_SHOW).expect("records");
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].name, "enp1s0");
        assert_eq!(records[0].interface_type, "ethernet");
        assert_eq!(records[0].state, "connected");
        assert_eq!(records[0].mac_address.as_deref(), Some("02:00:00:00:00:42"));
        assert_eq!(records[0].addresses[0].address, "192.168.100.63/24");
        assert_eq!(records[1].name, "wlan0");
        assert_eq!(records[1].state, "disconnected");
    }

    #[test]
    fn disconnected_is_not_misread_as_connected() {
        assert_eq!(normalise_state("30 (disconnected)"), "disconnected");
        assert_eq!(normalise_state("100 (connected)"), "connected");
    }

    #[test]
    fn escaped_wifi_rows_keep_colons_in_the_ssid() {
        let fields = split_nmcli_row("*:Studio\\:Lab:87").expect("row");
        assert_eq!(fields, ["*", "Studio:Lab", "87"]);
    }

    #[test]
    fn unsafe_interface_names_are_rejected_before_path_or_command_use() {
        assert!(safe_interface_name("enp1s0"));
        assert!(safe_interface_name("wlan0.42"));
        assert!(!safe_interface_name("../../etc/passwd"));
        assert!(!safe_interface_name("eth0;reboot"));
    }

    #[test]
    fn response_models_use_the_public_wire_names() {
        let value = serde_json::to_value(NetworkInterfaceStatus {
            name: "enp1s0".to_owned(),
            interface_type: "ethernet".to_owned(),
            state: "connected".to_owned(),
            connection_name: None,
            mac_address: None,
            mtu: Some(1500),
            link_speed_mbps: Some(10_000),
            addresses: vec![],
            gateway: None,
            dns_servers: vec![],
            wifi_ssid: None,
            wifi_signal_percent: None,
            internet: InternetReachability {
                reachable: true,
                gateway_reachable: Some(true),
                dns_reachable: Some(true),
                checked_at: "2026-08-29T00:00:00Z".to_owned(),
            },
        })
        .expect("serialize");
        assert_eq!(value["type"], "ethernet");
        assert_eq!(value["link_speed_mbps"], 10_000);
        assert_eq!(value["internet"]["reachable"], true);
    }
}
