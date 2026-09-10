use super::*;

pub(super) fn inspect_cluster_firewall(
    backend: &DockerBackend,
    table: &str,
    marker: &str,
    interface: &str,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
) -> Result<Option<bool>, BackendError> {
    Ok(cluster_firewall_evidence(backend, table)?.map(|evidence| {
        exact_cluster_firewall_policy(
            &evidence,
            table,
            marker,
            interface,
            local_address,
            peer_address,
        )
    }))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn discover_owned_cluster_firewall_interface(
    backend: &DockerBackend,
    transaction_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    peer_node_id: uuid::Uuid,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
) -> Result<Option<String>, BackendError> {
    let table = cluster_firewall_table(cluster_id, transaction_id);
    let prefix = format!(
        "sparkpilot-cluster-firewall-v1:transaction={transaction_id}:cluster={cluster_id}:local-node={local_node_id}:peer-node={peer_node_id}:local-address={local_address}:peer-address={peer_address}:interface="
    );
    let Some(evidence) = cluster_firewall_evidence(backend, &table)? else {
        return Ok(None);
    };
    let Some(interface) = exact_table_marker(&evidence, &table)
        .and_then(|comment| comment.strip_prefix(&prefix))
        .filter(|suffix| !suffix.contains(':') && valid_interface_name(suffix))
    else {
        return Err(BackendError::Failure(
            "the cluster firewall collision has no exact ownership marker".into(),
        ));
    };
    let interface = interface.to_owned();
    let marker = cluster_firewall_owner_marker(
        transaction_id,
        cluster_id,
        local_node_id,
        peer_node_id,
        local_address,
        peer_address,
        &interface,
    );
    if !exact_cluster_firewall_policy(
        &evidence,
        &table,
        &marker,
        &interface,
        local_address,
        peer_address,
    ) {
        return Err(BackendError::Failure(
            "the cluster firewall collision has changed ownership evidence".into(),
        ));
    }
    Ok(Some(interface))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn install_cluster_firewall(
    backend: &DockerBackend,
    interface: &str,
    transaction_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    peer_node_id: uuid::Uuid,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
) -> Result<bool, BackendError> {
    let table = cluster_firewall_table(cluster_id, transaction_id);
    let marker = cluster_firewall_owner_marker(
        transaction_id,
        cluster_id,
        local_node_id,
        peer_node_id,
        local_address,
        peer_address,
        interface,
    );
    match inspect_cluster_firewall(
        backend,
        &table,
        &marker,
        interface,
        local_address,
        peer_address,
    )? {
        Some(true) => return Ok(true),
        Some(false) => {
            return Err(BackendError::Failure(
                "the cluster firewall name belongs to a foreign or changed policy".into(),
            ));
        }
        None => {}
    }
    let script = firewall_install_script(&table, &marker, interface, local_address, peer_address);
    let output =
        backend.run_appliance(NFT_BIN, vec!["--file".into(), "-".into()], Some(&script))?;
    if !output.success()
        || inspect_cluster_firewall(
            backend,
            &table,
            &marker,
            interface,
            local_address,
            peer_address,
        )? != Some(true)
    {
        return Err(BackendError::Failure(
            "the exact member-only cluster firewall could not be installed".into(),
        ));
    }
    Ok(false)
}

#[allow(clippy::too_many_arguments)]
pub(super) fn require_cluster_firewall(
    backend: &DockerBackend,
    transaction_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    peer_node_id: uuid::Uuid,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
    interface: &str,
) -> Result<(), BackendError> {
    let table = cluster_firewall_table(cluster_id, transaction_id);
    let marker = cluster_firewall_owner_marker(
        transaction_id,
        cluster_id,
        local_node_id,
        peer_node_id,
        local_address,
        peer_address,
        interface,
    );
    if inspect_cluster_firewall(
        backend,
        &table,
        &marker,
        interface,
        local_address,
        peer_address,
    )? != Some(true)
    {
        return Err(BackendError::Failure(
            "the exact member-only cluster firewall is absent or changed".into(),
        ));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) fn cleanup_cluster_firewall(
    backend: &DockerBackend,
    transaction_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    peer_node_id: uuid::Uuid,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
    interface: &str,
) -> Result<bool, BackendError> {
    let table = cluster_firewall_table(cluster_id, transaction_id);
    let marker = cluster_firewall_owner_marker(
        transaction_id,
        cluster_id,
        local_node_id,
        peer_node_id,
        local_address,
        peer_address,
        interface,
    );
    match inspect_cluster_firewall(
        backend,
        &table,
        &marker,
        interface,
        local_address,
        peer_address,
    )? {
        None => return Ok(false),
        Some(false) => {
            return Err(BackendError::Failure(
                "refusing to remove a foreign cluster firewall collision".into(),
            ));
        }
        Some(true) => {}
    }
    let output = backend.run_appliance(
        NFT_BIN,
        vec![
            "delete".into(),
            "table".into(),
            "inet".into(),
            table.clone(),
        ],
        None,
    )?;
    if !output.success()
        || inspect_cluster_firewall(
            backend,
            &table,
            &marker,
            interface,
            local_address,
            peer_address,
        )?
        .is_some()
    {
        return Err(BackendError::Failure(
            "the transaction-owned cluster firewall cleanup was not proved".into(),
        ));
    }
    Ok(true)
}

#[allow(clippy::too_many_arguments)]
pub(super) fn cleanup_cluster_firewall_without_profile(
    backend: &DockerBackend,
    transaction_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    peer_node_id: uuid::Uuid,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
) -> Result<bool, BackendError> {
    let Some(interface) = discover_owned_cluster_firewall_interface(
        backend,
        transaction_id,
        cluster_id,
        local_node_id,
        peer_node_id,
        local_address,
        peer_address,
    )?
    else {
        return Ok(false);
    };
    cleanup_cluster_firewall(
        backend,
        transaction_id,
        cluster_id,
        local_node_id,
        peer_node_id,
        local_address,
        peer_address,
        &interface,
    )
}
