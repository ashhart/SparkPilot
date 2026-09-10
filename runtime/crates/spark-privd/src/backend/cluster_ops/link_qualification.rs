use super::*;

pub(super) struct QualifiedClusterLink {
    pub(super) interface: String,
    pub(super) local_mac: String,
    pub(super) neighbour_mac: String,
    pub(super) speed_mbps: u64,
    pub(super) mtu: u64,
}

#[allow(clippy::too_many_arguments)]
pub(super) fn qualify_owned_cluster_link(
    backend: &DockerBackend,
    transaction_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    peer_node_id: uuid::Uuid,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
) -> Result<QualifiedClusterLink, BackendError> {
    let profile = cluster_link_profile(cluster_id, transaction_id);
    let marker = cluster_link_owner_marker(
        transaction_id,
        cluster_id,
        local_node_id,
        peer_node_id,
        local_address,
        peer_address,
    );
    let evidence = inspect_cluster_profile(backend, &profile)?.ok_or_else(|| {
        BackendError::Failure("the transaction-owned cluster profile is unavailable".into())
    })?;
    if !profile_matches(&evidence, &profile, &marker, local_address) {
        return Err(BackendError::Failure(
            "the cluster profile name belongs to different immutable settings".into(),
        ));
    }
    let interface = evidence.interface;
    if interface.is_empty()
        || interface.len() >= libc::IF_NAMESIZE
        || !interface
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
        || !fs::read_to_string(
            backend
                .network_sysfs_root
                .join(&interface)
                .join("device/vendor"),
        )
        .is_ok_and(|vendor| vendor.trim().eq_ignore_ascii_case(CONNECTX_VENDOR))
    {
        return Err(BackendError::Failure(
            "the transaction profile is not bound to a ConnectX interface".into(),
        ));
    }
    let address_output = backend.run_appliance(
        IP_BIN,
        vec![
            "-o".into(),
            "-4".into(),
            "address".into(),
            "show".into(),
            "dev".into(),
            interface.clone(),
        ],
        None,
    )?;
    let expected_cidr = format!("{local_address}/30");
    if !address_output.success()
        || !String::from_utf8_lossy(&address_output.stdout)
            .split_ascii_whitespace()
            .any(|field| field == expected_cidr)
    {
        return Err(BackendError::Failure(
            "the ConnectX interface does not own its proposed address".into(),
        ));
    }
    let interface_root = backend.network_sysfs_root.join(&interface);
    let carrier = fs::read_to_string(interface_root.join("carrier"))
        .map_err(|_| BackendError::Failure("ConnectX carrier is unavailable".into()))?;
    let speed_mbps = fs::read_to_string(interface_root.join("speed"))
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .unwrap_or_default();
    let mtu = fs::read_to_string(interface_root.join("mtu"))
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .unwrap_or_default();
    let local_mac = fs::read_to_string(interface_root.join("address"))
        .ok()
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| valid_mac_address(value))
        .ok_or_else(|| BackendError::Failure("the ConnectX MAC address is invalid".into()))?;
    if carrier.trim() != "1" || speed_mbps < 200_000 || mtu != 9_000 {
        return Err(BackendError::Failure(
            "the ConnectX link is not carrier-up at 200 Gb/s with MTU 9000".into(),
        ));
    }
    let peer = peer_address.to_string();
    let arping = backend.run_appliance(
        ARPING_BIN,
        vec![
            "-c".into(),
            "3".into(),
            "-w".into(),
            "5".into(),
            "-I".into(),
            interface.clone(),
            peer.clone(),
        ],
        None,
    )?;
    if !arping.success() {
        return Err(BackendError::Failure(
            "the assigned peer address did not answer on the ConnectX interface".into(),
        ));
    }
    let neighbour = backend.run_appliance(
        IP_BIN,
        vec![
            "neighbour".into(),
            "show".into(),
            "to".into(),
            peer,
            "dev".into(),
            interface.clone(),
        ],
        None,
    )?;
    let fields = String::from_utf8_lossy(&neighbour.stdout);
    let neighbour_mac = fields
        .split_ascii_whitespace()
        .collect::<Vec<_>>()
        .windows(2)
        .find_map(|pair| (pair[0] == "lladdr").then_some(pair[1]))
        .filter(|mac| valid_mac_address(mac))
        .ok_or_else(|| {
            BackendError::Failure("the peer neighbour identity was not resolved".into())
        })?
        .to_owned();
    require_cluster_firewall(
        backend,
        transaction_id,
        cluster_id,
        local_node_id,
        peer_node_id,
        local_address,
        peer_address,
        &interface,
    )?;
    Ok(QualifiedClusterLink {
        interface,
        local_mac,
        neighbour_mac,
        speed_mbps,
        mtu,
    })
}

#[allow(clippy::too_many_arguments)]
pub(super) fn probe_link(
    backend: &DockerBackend,
    request_id: uuid::Uuid,
    transaction_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    peer_node_id: uuid::Uuid,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
) -> Result<PrivilegedResponse, BackendError> {
    if local_node_id == peer_node_id
        || local_address == peer_address
        || !DockerBackend::cluster_address_allowed(&local_address)
        || !DockerBackend::cluster_address_allowed(&peer_address)
    {
        return Err(BackendError::InvalidInput(
            "cluster link probe requires distinct transaction-owned nodes and addresses".into(),
        ));
    }
    let profile = cluster_link_profile(cluster_id, transaction_id);
    if backend.plan_only {
        return Ok(PrivilegedResponse {
            request_id,
            accepted: true,
            code: "planned".into(),
            message: "cluster peer proof plan approved".into(),
            details: serde_json::json!({
                "profile": profile,
                "commands": [
                    [NMCLI_BIN, "--get-values", "<exact-owned-settings>", "connection", "show", "id", "<transaction-profile>"],
                    [IP_BIN, "-o", "-4", "address", "show", "dev", "<resolved-connectx-interface>"],
                    [ARPING_BIN, "-c", "3", "-w", "5", "-I", "<resolved-connectx-interface>", "<assigned-peer-address>"],
                    [IP_BIN, "neighbour", "show", "to", "<assigned-peer-address>", "dev", "<resolved-connectx-interface>"],
                ],
                "caller_supplies_interface": false,
            }),
        });
    }
    let qualified = qualify_owned_cluster_link(
        backend,
        transaction_id,
        cluster_id,
        local_node_id,
        peer_node_id,
        local_address,
        peer_address,
    )?;
    Ok(PrivilegedResponse {
        request_id,
        accepted: true,
        code: "cluster_peer_proved".into(),
        message: "proved the assigned peer over the transaction-owned ConnectX link".into(),
        details: serde_json::json!({
            "transaction_id": transaction_id,
            "cluster_id": cluster_id,
            "local_node_id": local_node_id,
            "peer_node_id": peer_node_id,
            "local_address": local_address,
            "peer_address": peer_address,
            "interface": qualified.interface,
            "local_mac": qualified.local_mac,
            "neighbour_mac": qualified.neighbour_mac,
            "speed_mbps": qualified.speed_mbps,
            "mtu": qualified.mtu,
        }),
    })
}
