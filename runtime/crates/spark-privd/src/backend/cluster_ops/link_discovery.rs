use super::*;

pub(super) fn cluster_link_profile(cluster_id: uuid::Uuid, transaction_id: uuid::Uuid) -> String {
    format!(
        "{CLUSTER_LINK_PREFIX}-{}-{}",
        cluster_id.simple(),
        transaction_id.simple()
    )
}

#[allow(clippy::too_many_arguments)]
pub(super) fn cluster_link_owner_marker(
    transaction_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    peer_node_id: uuid::Uuid,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
) -> String {
    let canonical = format!(
        "sparkpilot-cluster-link-v1\0{transaction_id}\0{cluster_id}\0{local_node_id}\0{peer_node_id}\0{local_address}\0{peer_address}"
    );
    format!("sparkpilot-cluster-link-{:x}", Sha256::digest(canonical))
}

#[derive(Clone, Debug)]
pub(super) struct ClusterProfileEvidence {
    pub(super) id: String,
    pub(super) stable_id: String,
    pub(super) interface: String,
    pub(super) autoconnect: String,
    pub(super) ipv4_method: String,
    pub(super) ipv4_addresses: String,
    pub(super) ipv4_gateway: String,
    pub(super) ipv4_routes: String,
    pub(super) ipv4_dns: String,
    pub(super) ipv4_dns_search: String,
    pub(super) ipv4_route_table: String,
    pub(super) ipv4_route_metric: String,
    pub(super) never_default: String,
    pub(super) ignore_auto_dns: String,
    pub(super) ipv6_method: String,
    pub(super) mtu: String,
}

pub(super) fn inspect_cluster_profile(
    backend: &DockerBackend,
    profile: &str,
) -> Result<Option<ClusterProfileEvidence>, BackendError> {
    let fields = "connection.id,connection.stable-id,connection.interface-name,connection.autoconnect,ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.routes,ipv4.dns,ipv4.dns-search,ipv4.route-table,ipv4.route-metric,ipv4.never-default,ipv4.ignore-auto-dns,ipv6.method,802-3-ethernet.mtu";
    let output = backend.run_appliance(
        NMCLI_BIN,
        vec![
            "--terse".into(),
            "--escape".into(),
            "no".into(),
            "--mode".into(),
            "multiline".into(),
            "--fields".into(),
            fields.into(),
            "connection".into(),
            "show".into(),
            "id".into(),
            profile.into(),
        ],
        None,
    )?;
    if !output.success() {
        let detail = output.stderr_text().to_ascii_lowercase();
        if detail.contains("unknown connection") || detail.contains("not found") {
            return Ok(None);
        }
        return Err(BackendError::Failure(
            "NetworkManager could not inspect the cluster profile".into(),
        ));
    }
    let profile_output = String::from_utf8_lossy(&output.stdout);
    let mut values = HashMap::new();
    for line in profile_output.lines() {
        let (key, value) = line.split_once(':').ok_or_else(|| {
            BackendError::Failure(
                "NetworkManager returned malformed cluster profile evidence".into(),
            )
        })?;
        if values.insert(key, value.to_owned()).is_some() {
            return Err(BackendError::Failure(
                "NetworkManager repeated cluster profile evidence".into(),
            ));
        }
    }
    let get = |key: &str| {
        values.get(key).cloned().ok_or_else(|| {
            BackendError::Failure("NetworkManager omitted cluster profile evidence".into())
        })
    };
    if values.len() != 16 {
        return Err(BackendError::Failure(
            "NetworkManager returned malformed cluster profile evidence".into(),
        ));
    }
    Ok(Some(ClusterProfileEvidence {
        id: get("connection.id")?,
        stable_id: get("connection.stable-id")?,
        interface: get("connection.interface-name")?,
        autoconnect: get("connection.autoconnect")?,
        ipv4_method: get("ipv4.method")?,
        ipv4_addresses: get("ipv4.addresses")?,
        ipv4_gateway: get("ipv4.gateway")?,
        ipv4_routes: get("ipv4.routes")?,
        ipv4_dns: get("ipv4.dns")?,
        ipv4_dns_search: get("ipv4.dns-search")?,
        ipv4_route_table: get("ipv4.route-table")?,
        ipv4_route_metric: get("ipv4.route-metric")?,
        never_default: get("ipv4.never-default")?,
        ignore_auto_dns: get("ipv4.ignore-auto-dns")?,
        ipv6_method: get("ipv6.method")?,
        mtu: get("802-3-ethernet.mtu")?,
    }))
}

pub(super) fn yes(value: &str) -> bool {
    matches!(value, "yes" | "true" | "1")
}

pub(super) fn empty_network_value(value: &str) -> bool {
    value.trim().is_empty() || value.trim() == "--"
}

pub(super) fn profile_matches(
    evidence: &ClusterProfileEvidence,
    profile: &str,
    marker: &str,
    local_address: Ipv4Addr,
) -> bool {
    evidence.id == profile
        && evidence.stable_id == marker
        && valid_interface_name(&evidence.interface)
        && !yes(&evidence.autoconnect)
        && evidence.ipv4_method == "manual"
        && evidence.ipv4_addresses.trim() == format!("{local_address}/30")
        && empty_network_value(&evidence.ipv4_gateway)
        && empty_network_value(&evidence.ipv4_routes)
        && empty_network_value(&evidence.ipv4_dns)
        && empty_network_value(&evidence.ipv4_dns_search)
        && evidence.ipv4_route_table.trim() == "0"
        && evidence.ipv4_route_metric.trim() == "-1"
        && yes(&evidence.never_default)
        && yes(&evidence.ignore_auto_dns)
        && evidence.ipv6_method == "disabled"
        && evidence.mtu == CLUSTER_LINK_MTU
}

pub(super) fn parse_active_ethernet_devices(
    output: &[u8],
) -> Result<HashSet<String>, BackendError> {
    let mut devices = HashSet::new();
    for line in String::from_utf8_lossy(output)
        .lines()
        .filter(|line| !line.trim().is_empty())
    {
        let (device, connection_type) = line.split_once(':').ok_or_else(|| {
            BackendError::Failure(
                "NetworkManager returned malformed active-connection evidence".into(),
            )
        })?;
        if matches!(connection_type, "ethernet" | "802-3-ethernet") {
            if !valid_interface_name(device) {
                return Err(BackendError::Failure(
                    "NetworkManager returned an active Ethernet connection without a device".into(),
                ));
            }
            devices.insert(device.to_owned());
        }
    }
    Ok(devices)
}

pub(super) fn valid_interface_name(value: &str) -> bool {
    !value.is_empty()
        && value != "--"
        && value.len() < libc::IF_NAMESIZE
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
}

pub(super) fn parse_default_route_devices(output: &[u8]) -> Result<HashSet<String>, BackendError> {
    let mut devices = HashSet::new();
    for line in String::from_utf8_lossy(output)
        .lines()
        .filter(|line| !line.trim().is_empty())
    {
        let fields = line.split_ascii_whitespace().collect::<Vec<_>>();
        if fields.first() != Some(&"default") {
            return Err(BackendError::Failure(
                "the default-route query returned unexpected evidence".into(),
            ));
        }
        let device = fields
            .windows(2)
            .find_map(|pair| (pair[0] == "dev").then_some(pair[1]))
            .filter(|device| valid_interface_name(device))
            .ok_or_else(|| {
                BackendError::Failure("a default route did not name its interface".into())
            })?;
        devices.insert(device.to_owned());
    }
    Ok(devices)
}

pub(super) fn choose_connectx_candidate(
    mut candidates: Vec<String>,
    excluded: &HashSet<String>,
) -> Result<String, BackendError> {
    candidates.retain(|candidate| !excluded.contains(candidate));
    candidates.sort();
    candidates.dedup();
    candidates.into_iter().next().ok_or_else(|| {
        BackendError::Failure(
            "no unused carrier-up ConnectX interface is available for the cluster transaction"
                .into(),
        )
    })
}

pub(super) fn connectx_interface(backend: &DockerBackend) -> Result<String, BackendError> {
    let active = backend.run_appliance(
        NMCLI_BIN,
        vec![
            "--terse".into(),
            "--escape".into(),
            "no".into(),
            "--fields".into(),
            "DEVICE,TYPE".into(),
            "connection".into(),
            "show".into(),
            "--active".into(),
        ],
        None,
    )?;
    if !active.success() {
        return Err(BackendError::Failure(
            "NetworkManager could not identify active Ethernet interfaces".into(),
        ));
    }
    let default_routes = backend.run_appliance(
        IP_BIN,
        vec!["-4".into(), "route".into(), "show".into(), "default".into()],
        None,
    )?;
    if !default_routes.success() {
        return Err(BackendError::Failure(
            "the kernel could not identify the default-route interface".into(),
        ));
    }
    let mut excluded = parse_active_ethernet_devices(&active.stdout)?;
    excluded.extend(parse_default_route_devices(&default_routes.stdout)?);
    let entries = fs::read_dir(&backend.network_sysfs_root).map_err(|error| {
        BackendError::Failure(format!("could not inspect network interfaces: {error}"))
    })?;
    let candidates = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !valid_interface_name(&name) {
                return None;
            }
            let path = entry.path();
            let vendor = fs::read_to_string(path.join("device/vendor")).ok()?;
            if vendor.trim() != CONNECTX_VENDOR {
                return None;
            }
            let carrier = fs::read_to_string(path.join("carrier")).ok()?;
            let state = fs::read_to_string(path.join("operstate")).ok()?;
            (carrier.trim() == "1" && state.trim() == "up").then_some(name)
        })
        .collect::<Vec<_>>();
    choose_connectx_candidate(candidates, &excluded)
}

pub(super) fn valid_mac_address(value: &str) -> bool {
    value.len() == 17
        && value.split(':').count() == 6
        && value
            .split(':')
            .all(|octet| octet.len() == 2 && octet.bytes().all(|byte| byte.is_ascii_hexdigit()))
}
