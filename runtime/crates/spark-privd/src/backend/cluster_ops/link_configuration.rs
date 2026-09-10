use super::*;

pub(super) fn cluster_link_phase_args(
    phase: ClusterLinkPhase,
    interface: &str,
    profile: &str,
    marker: &str,
    local_cidr: &str,
) -> Vec<String> {
    let mut args = vec!["--wait".into(), CLUSTER_LINK_WAIT_SECONDS.into()];
    args.extend(match phase {
        ClusterLinkPhase::Prepare => vec![
            "connection".into(),
            "add".into(),
            "type".into(),
            "ethernet".into(),
            "ifname".into(),
            interface.into(),
            "con-name".into(),
            profile.into(),
            "connection.stable-id".into(),
            marker.into(),
            "connection.autoconnect".into(),
            "no".into(),
            "ipv4.method".into(),
            "manual".into(),
            "ipv4.addresses".into(),
            local_cidr.into(),
            "ipv4.gateway".into(),
            "".into(),
            "ipv4.routes".into(),
            "".into(),
            "ipv4.dns".into(),
            "".into(),
            "ipv4.dns-search".into(),
            "".into(),
            "ipv4.route-table".into(),
            "0".into(),
            "ipv4.route-metric".into(),
            "-1".into(),
            "ipv4.never-default".into(),
            "yes".into(),
            "ipv4.ignore-auto-dns".into(),
            "yes".into(),
            "ipv6.method".into(),
            "disabled".into(),
            "802-3-ethernet.mtu".into(),
            CLUSTER_LINK_MTU.into(),
        ],
        ClusterLinkPhase::Commit => vec![
            "connection".into(),
            "up".into(),
            "id".into(),
            profile.into(),
        ],
        ClusterLinkPhase::Rollback => vec![
            "connection".into(),
            "delete".into(),
            "id".into(),
            profile.into(),
        ],
    });
    args
}

#[allow(clippy::too_many_arguments)]
pub(super) fn configure_link(
    backend: &DockerBackend,
    request_id: uuid::Uuid,
    transaction_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    peer_node_id: uuid::Uuid,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
    phase: ClusterLinkPhase,
) -> Result<PrivilegedResponse, BackendError> {
    if local_node_id == peer_node_id
        || local_address == peer_address
        || !DockerBackend::cluster_address_allowed(&local_address)
        || !DockerBackend::cluster_address_allowed(&peer_address)
    {
        return Err(BackendError::InvalidInput(
            "cluster link requires distinct nodes and addresses in 172.31.252.0/24".into(),
        ));
    }
    let profile = cluster_link_profile(cluster_id, transaction_id);
    let marker = cluster_link_owner_marker(
        transaction_id,
        cluster_id,
        local_node_id,
        peer_node_id,
        local_address,
        peer_address,
    );
    let local_cidr = format!("{local_address}/30");
    if backend.plan_only {
        return Ok(PrivilegedResponse {
            request_id,
            accepted: true,
            code: "planned".into(),
            message: "cluster link transaction plan approved".into(),
            details: serde_json::json!({
                "program": NMCLI_BIN,
                "profile": profile,
                "owner_marker": marker,
                "inspects_exact_settings_first": true,
                "caller_supplies_interface": false,
                "phase": phase,
            }),
        });
    }

    let existing = inspect_cluster_profile(backend, &profile)?;
    if let Some(evidence) = &existing
        && !profile_matches(evidence, &profile, &marker, local_address)
    {
        return Err(BackendError::InvalidInput(
            "the cluster profile name belongs to different immutable settings".into(),
        ));
    }
    if matches!(phase, ClusterLinkPhase::Rollback) && existing.is_none() {
        let firewall_removed = cleanup_cluster_firewall_without_profile(
            backend,
            transaction_id,
            cluster_id,
            local_node_id,
            peer_node_id,
            local_address,
            peer_address,
        )?;
        return Ok(PrivilegedResponse {
            request_id,
            accepted: true,
            code: "cluster_link_rolled_back".into(),
            message: "cluster link transaction was already absent".into(),
            details: serde_json::json!({
                "transaction_id": transaction_id,
                "profile": profile,
                "already_absent": true,
                "firewall_removed": firewall_removed,
            }),
        });
    }
    if !matches!(phase, ClusterLinkPhase::Prepare) && existing.is_none() {
        return Err(BackendError::InvalidInput(
            "the transaction-owned cluster profile is unavailable".into(),
        ));
    }
    if matches!(phase, ClusterLinkPhase::Prepare)
        && let Some(evidence) = &existing
    {
        let interface = evidence.interface.clone();
        return Ok(PrivilegedResponse {
            request_id,
            accepted: true,
            code: "cluster_link_prepared".into(),
            message: "the exact cluster link transaction is already prepared".into(),
            details: serde_json::json!({
                "transaction_id": transaction_id,
                "profile": profile,
                "interface": interface,
                "reused": true,
            }),
        });
    }

    let interface = if matches!(phase, ClusterLinkPhase::Prepare) {
        connectx_interface(backend)?
    } else {
        existing
            .as_ref()
            .expect("checked existing profile")
            .interface
            .clone()
    };
    if matches!(phase, ClusterLinkPhase::Rollback) {
        cleanup_cluster_firewall(
            backend,
            transaction_id,
            cluster_id,
            local_node_id,
            peer_node_id,
            local_address,
            peer_address,
            &interface,
        )?;
    }
    let args = cluster_link_phase_args(phase, &interface, &profile, &marker, &local_cidr);
    let output = backend.run_appliance(NMCLI_BIN, args, None)?;
    if !output.success() {
        return Err(BackendError::Failure(format!(
            "NetworkManager refused the cluster link phase: {}",
            output.stderr_text()
        )));
    }
    let firewall_reused = if matches!(phase, ClusterLinkPhase::Commit) {
        Some(install_cluster_firewall(
            backend,
            &interface,
            transaction_id,
            cluster_id,
            local_node_id,
            peer_node_id,
            local_address,
            peer_address,
        )?)
    } else {
        None
    };
    Ok(PrivilegedResponse {
        request_id,
        accepted: true,
        code: match phase {
            ClusterLinkPhase::Prepare => "cluster_link_prepared",
            ClusterLinkPhase::Commit => "cluster_link_committed",
            ClusterLinkPhase::Rollback => "cluster_link_rolled_back",
        }
        .into(),
        message: "cluster link transaction phase completed".into(),
        details: serde_json::json!({
            "transaction_id": transaction_id,
            "cluster_id": cluster_id,
            "local_node_id": local_node_id,
            "peer_node_id": peer_node_id,
            "local_address": local_address,
            "peer_address": peer_address,
            "profile": profile,
            "interface": interface,
            "phase": phase,
            "member_only_firewall": matches!(phase, ClusterLinkPhase::Commit),
            "firewall_reused": firewall_reused,
        }),
    })
}
