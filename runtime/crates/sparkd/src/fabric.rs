//! Observe ConnectX through sysfs, ip JSON and Netplan provenance without privileged mutation access.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::time::Duration;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tokio::process::Command;
use tokio::time::timeout;

use crate::cluster::{AuthenticatedFabricLink, EXTERNALLY_CONFIGURED};

const CONNECTX_VENDOR: &str = "0x15b3";
const MINIMUM_LINK_MBPS: u64 = 200_000;
const COMMAND_TIMEOUT: Duration = Duration::from_secs(4);
const MAX_NETPLAN_FILE_BYTES: u64 = 1_048_576;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FabricStatus {
    pub observed_at: String,
    pub available: bool,
    pub unavailable_reason: Option<String>,
    pub configuration_owner: String,
    pub automatic_topology_available: bool,
    pub takeover_available: bool,
    pub address_evidence_available: bool,
    pub route_evidence_available: bool,
    pub netplan_evidence_available: bool,
    pub netplan_sources: Vec<String>,
    pub ports: Vec<FabricPortStatus>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FabricPortStatus {
    pub port_id: String,
    pub interfaces: Vec<String>,
    pub physical_link: String,
    pub negotiated_speed_mbps: Option<u64>,
    pub mtu: Option<u32>,
    pub addresses: Vec<String>,
    pub routes: Vec<String>,
    pub peer_proof: String,
    pub authenticated_peer_node_id: Option<String>,
    pub peer_proof_expires_at: Option<String>,
}

#[async_trait]
pub trait FabricStatusProvider: Send + Sync {
    async fn observe(&self, observed_at: &str) -> FabricStatus;
}

#[derive(Debug, Clone)]
pub struct SysfsFabricStatusProvider {
    sysfs_root: PathBuf,
    netplan_root: PathBuf,
}

/// Where the kernel exposes ConnectX link state; the change watcher reads the same root.
pub const DEFAULT_SYSFS_ROOT: &str = "/sys/class/net";

impl Default for SysfsFabricStatusProvider {
    fn default() -> Self {
        Self {
            sysfs_root: PathBuf::from(DEFAULT_SYSFS_ROOT),
            netplan_root: PathBuf::from("/etc/netplan"),
        }
    }
}

impl SysfsFabricStatusProvider {
    #[cfg(test)]
    fn with_roots(sysfs_root: impl Into<PathBuf>, netplan_root: impl Into<PathBuf>) -> Self {
        Self {
            sysfs_root: sysfs_root.into(),
            netplan_root: netplan_root.into(),
        }
    }
}

#[async_trait]
impl FabricStatusProvider for SysfsFabricStatusProvider {
    async fn observe(&self, observed_at: &str) -> FabricStatus {
        let address_json = ip_json(&["-json", "address", "show"]).await;
        let route_json = ip_json(&["-json", "route", "show", "table", "all"]).await;
        observe_filesystem(
            &self.sysfs_root,
            &self.netplan_root,
            observed_at,
            address_json.as_deref(),
            route_json.as_deref(),
        )
    }
}

async fn ip_json(arguments: &[&str]) -> Option<String> {
    let program = [Path::new("/usr/sbin/ip"), Path::new("/usr/bin/ip")]
        .into_iter()
        .find(|path| path.is_file())?;
    let output = timeout(
        COMMAND_TIMEOUT,
        Command::new(program)
            .args(arguments)
            .env("LC_ALL", "C")
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

#[derive(Debug)]
struct InterfaceEvidence {
    name: String,
    port_id: String,
    carrier: bool,
    speed_mbps: Option<u64>,
    mtu: Option<u32>,
}

fn read_trimmed(directory: &Path, name: &str) -> Option<String> {
    std::fs::read_to_string(directory.join(name))
        .ok()
        .map(|value| value.trim().to_owned())
}

fn port_id(directory: &Path, interface: &str) -> String {
    let device = std::fs::canonicalize(directory.join("device"))
        .ok()
        .and_then(|path| {
            path.file_name()
                .map(|name| name.to_string_lossy().into_owned())
        })
        .unwrap_or_else(|| interface.to_owned());
    let physical_port = read_trimmed(directory, "phys_port_name")
        .or_else(|| read_trimmed(directory, "dev_port"))
        .unwrap_or_else(|| interface.to_owned());
    format!("{device}:{physical_port}")
}

/// §35.3.1: the physical-link dimension, shared by the on-demand snapshot and the change watcher.
pub(crate) fn physical_link_state(carrier: bool, speed: Option<u64>) -> &'static str {
    match (carrier, speed) {
        (false, _) => "down",
        (true, Some(speed)) if speed >= MINIMUM_LINK_MBPS => "negotiated_200_gbe",
        (true, Some(_)) => "speed_mismatch",
        (true, None) => "carrier",
    }
}

/// Read only sysfs so a change watcher can run often without spawning `ip` or touching the database.
pub(crate) fn observe_port_links(
    root: &Path,
) -> Result<BTreeMap<String, (bool, Option<u64>)>, String> {
    let mut ports: BTreeMap<String, (bool, Option<u64>)> = BTreeMap::new();
    for interface in connectx_interfaces(root)? {
        let entry = ports.entry(interface.port_id).or_insert((false, None));
        entry.0 |= interface.carrier;
        entry.1 = entry.1.max(interface.speed_mbps);
    }
    Ok(ports)
}

fn connectx_interfaces(root: &Path) -> Result<Vec<InterfaceEvidence>, String> {
    let entries = std::fs::read_dir(root).map_err(|error| error.to_string())?;
    let mut interfaces = Vec::new();
    for entry in entries.flatten() {
        let directory = entry.path();
        if read_trimmed(&directory, "device/vendor").as_deref() != Some(CONNECTX_VENDOR) {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        let carrier = read_trimmed(&directory, "carrier").as_deref() == Some("1");
        let speed_mbps = read_trimmed(&directory, "speed")
            .and_then(|value| value.parse::<i64>().ok())
            .filter(|speed| *speed > 0)
            .map(|speed| speed as u64);
        let mtu = read_trimmed(&directory, "mtu").and_then(|value| value.parse().ok());
        interfaces.push(InterfaceEvidence {
            port_id: port_id(&directory, &name),
            name,
            carrier,
            speed_mbps,
            mtu,
        });
    }
    interfaces.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(interfaces)
}

#[derive(Debug, Deserialize)]
struct IpAddressRecord {
    ifname: String,
    #[serde(default)]
    addr_info: Vec<IpAddressInfo>,
}

#[derive(Debug, Deserialize)]
struct IpAddressInfo {
    #[serde(default)]
    family: String,
    local: Option<String>,
    prefixlen: Option<u8>,
}

#[derive(Debug, Deserialize)]
struct IpRouteRecord {
    dev: Option<String>,
    dst: Option<String>,
    gateway: Option<String>,
}

fn addresses_by_interface(json: Option<&str>) -> (bool, HashMap<String, Vec<String>>) {
    let Some(records) =
        json.and_then(|value| serde_json::from_str::<Vec<IpAddressRecord>>(value).ok())
    else {
        return (false, HashMap::new());
    };
    let mut result = HashMap::new();
    for record in records {
        let addresses = record
            .addr_info
            .into_iter()
            .filter_map(|address| {
                let local = address.local?;
                let prefix = address.prefixlen?;
                matches!(address.family.as_str(), "inet" | "inet6")
                    .then(|| format!("{local}/{prefix}"))
            })
            .collect::<Vec<_>>();
        result.insert(record.ifname, addresses);
    }
    (true, result)
}

fn routes_by_interface(json: Option<&str>) -> (bool, HashMap<String, Vec<String>>) {
    let Some(records) =
        json.and_then(|value| serde_json::from_str::<Vec<IpRouteRecord>>(value).ok())
    else {
        return (false, HashMap::new());
    };
    let mut result: HashMap<String, Vec<String>> = HashMap::new();
    for record in records {
        let Some(interface) = record.dev else {
            continue;
        };
        let mut route = record.dst.unwrap_or_else(|| "default".into());
        if let Some(gateway) = record.gateway {
            route.push_str(" via ");
            route.push_str(&gateway);
        }
        result.entry(interface).or_default().push(route);
    }
    for routes in result.values_mut() {
        routes.sort();
        routes.dedup();
    }
    (true, result)
}

fn matching_netplan_sources(root: &Path, interface_names: &[String]) -> (bool, Vec<String>) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return (false, Vec::new());
    };
    let mut sources = Vec::new();
    for entry in entries.flatten().take(64) {
        let path = entry.path();
        if !matches!(
            path.extension().and_then(|value| value.to_str()),
            Some("yaml" | "yml")
        ) {
            continue;
        }
        let Ok(metadata) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if !metadata.is_file() || metadata.len() > MAX_NETPLAN_FILE_BYTES {
            continue;
        }
        let Ok(contents) = std::fs::read_to_string(&path) else {
            continue;
        };
        if interface_names.iter().any(|name| contents.contains(name)) {
            sources.push(entry.file_name().to_string_lossy().into_owned());
        }
    }
    sources.sort();
    (true, sources)
}

fn observe_filesystem(
    sysfs_root: &Path,
    netplan_root: &Path,
    observed_at: &str,
    address_json: Option<&str>,
    route_json: Option<&str>,
) -> FabricStatus {
    let interfaces = match connectx_interfaces(sysfs_root) {
        Ok(interfaces) => interfaces,
        Err(_) => {
            return FabricStatus {
                observed_at: observed_at.into(),
                available: false,
                unavailable_reason: Some("ConnectX hardware inventory is unavailable.".into()),
                configuration_owner: "unconfigured".into(),
                automatic_topology_available: false,
                takeover_available: false,
                address_evidence_available: false,
                route_evidence_available: false,
                netplan_evidence_available: false,
                netplan_sources: Vec::new(),
                ports: Vec::new(),
            };
        }
    };
    let interface_names = interfaces
        .iter()
        .map(|item| item.name.clone())
        .collect::<Vec<_>>();
    let (address_evidence_available, addresses) = addresses_by_interface(address_json);
    let (route_evidence_available, routes) = routes_by_interface(route_json);
    let (netplan_evidence_available, netplan_sources) =
        matching_netplan_sources(netplan_root, &interface_names);

    let mut grouped: BTreeMap<String, Vec<InterfaceEvidence>> = BTreeMap::new();
    for interface in interfaces {
        grouped
            .entry(interface.port_id.clone())
            .or_default()
            .push(interface);
    }
    let ports = grouped
        .into_iter()
        .map(|(port_id, interfaces)| {
            let carrier = interfaces.iter().any(|item| item.carrier);
            let speed = interfaces.iter().filter_map(|item| item.speed_mbps).max();
            let physical_link = physical_link_state(carrier, speed);
            let mtu = interfaces.iter().filter_map(|item| item.mtu).max();
            let mut port_addresses = interfaces
                .iter()
                .flat_map(|item| addresses.get(&item.name).into_iter().flatten().cloned())
                .collect::<Vec<_>>();
            port_addresses.sort();
            port_addresses.dedup();
            let mut port_routes = interfaces
                .iter()
                .flat_map(|item| routes.get(&item.name).into_iter().flatten().cloned())
                .collect::<Vec<_>>();
            port_routes.sort();
            port_routes.dedup();
            FabricPortStatus {
                port_id,
                interfaces: interfaces.into_iter().map(|item| item.name).collect(),
                physical_link: physical_link.into(),
                negotiated_speed_mbps: speed,
                mtu,
                addresses: port_addresses,
                routes: port_routes,
                peer_proof: "unknown".into(),
                authenticated_peer_node_id: None,
                peer_proof_expires_at: None,
            }
        })
        .collect::<Vec<_>>();
    let externally_configured = !netplan_sources.is_empty()
        || ports
            .iter()
            .any(|port| !port.addresses.is_empty() || !port.routes.is_empty());
    FabricStatus {
        observed_at: observed_at.into(),
        available: true,
        unavailable_reason: None,
        configuration_owner: if externally_configured {
            EXTERNALLY_CONFIGURED.into()
        } else {
            "unconfigured".into()
        },
        automatic_topology_available: false,
        takeover_available: false,
        address_evidence_available,
        route_evidence_available,
        netplan_evidence_available,
        netplan_sources,
        ports,
    }
}

pub fn bind_authenticated_peers(
    status: &mut FabricStatus,
    local_node_id: &str,
    links: &[AuthenticatedFabricLink],
) {
    for port in &mut status.ports {
        let peer = links.iter().find_map(|link| {
            if link.member_a_node_id == local_node_id && link.member_a_port_id == port.port_id {
                Some((&link.member_b_node_id, &link.expires_at))
            } else if link.member_b_node_id == local_node_id
                && link.member_b_port_id == port.port_id
            {
                Some((&link.member_a_node_id, &link.expires_at))
            } else {
                None
            }
        });
        if let Some((peer_node_id, expires_at)) = peer {
            port.peer_proof = "authenticated_node".into();
            port.authenticated_peer_node_id = Some(peer_node_id.clone());
            port.peer_proof_expires_at = Some(expires_at.clone());
        } else if port.physical_link != "down" {
            // §10.6.2: carrier without proof is "checking the other end", never a trusted member line.
            port.peer_proof = "candidate".into();
        }
    }
    // A proven peer on an address from the reserved managed range is a fabric Spark Runtime configured.
    let managed = status.ports.iter().any(|port| {
        port.peer_proof == "authenticated_node"
            && port.addresses.iter().any(|address| {
                address
                    .split('/')
                    .next()
                    .and_then(|literal| literal.parse::<std::net::Ipv4Addr>().ok())
                    .is_some_and(|address| spark_core::is_managed_fabric_address(&address))
            })
    });
    if managed {
        status.configuration_owner = "spark_runtime_managed".into();
    }
}

#[cfg(test)]
#[path = "fabric/tests.rs"]
mod tests;
