use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    commands: appliance_commands::ApplianceCommands<'_>,
    network: network_inspection::NetworkInspection<'_>,
    network_rollbacks: &NetworkRollbackManager,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::ConfigureLanIpv4 {
            configuration_id,
            address,
            prefix_length,
            gateway,
            dns_servers,
            ..
        } => {
            if !valid_lan_ipv4(*address, *prefix_length, *gateway, dns_servers) {
                return Err(BackendError::InvalidInput(
                    "manual LAN IPv4 values are unsafe or internally inconsistent".into(),
                ));
            }
            let address_with_prefix = format!("{address}/{prefix_length}");
            let dns = dns_servers
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
                .join(",");
            let planned_args = vec![
                "--wait".into(),
                "20".into(),
                "connection".into(),
                "modify".into(),
                "uuid".into(),
                "<active-ordinary-lan-profile>".into(),
                "ipv4.method".into(),
                "manual".into(),
                "ipv4.addresses".into(),
                address_with_prefix.clone(),
                "ipv4.gateway".into(),
                gateway.to_string(),
                "ipv4.dns".into(),
                dns.clone(),
                "ipv4.ignore-auto-dns".into(),
                "yes".into(),
            ];
            if let Some(mut response) = commands.appliance_plan(
                request_id,
                "manual LAN IPv4 plan approved",
                NMCLI_BIN,
                &planned_args,
                false,
            ) {
                response.details["auto_revert_seconds"] = 30.into();
                return Ok(response);
            }
            let _network_mutation = network_rollbacks.begin_mutation()?;
            let (connection_uuid, interface) = network.active_lan_connection()?;
            let previous = network.snapshot_lan_ipv4(connection_uuid)?;
            // Refuse changes if arping is missing; a packaging recommendation does not guarantee this safety check is installed.
            let duplicate_check = match commands.run_appliance(
                ARPING_BIN,
                vec![
                    "-D".into(),
                    "-c".into(),
                    "2".into(),
                    "-w".into(),
                    "3".into(),
                    "-I".into(),
                    interface,
                    address.to_string(),
                ],
                None,
            ) {
                Ok(output) => output,
                Err(BackendError::Failure(message))
                    if message.contains("os error 2") || message.contains("No such file") =>
                {
                    return Ok(PrivilegedResponse::rejected(
                        request_id,
                        "NETWORK_ADDRESS_CHECK_UNAVAILABLE",
                        "The duplicate-address check needs iputils-arping, which is not installed on this Spark.",
                    ));
                }
                Err(error) => return Err(error),
            };
            if !duplicate_check.success() {
                return Ok(PrivilegedResponse::rejected(
                    request_id,
                    "NETWORK_ADDRESS_IN_USE",
                    "Another device is already using that IPv4 address.",
                ));
            }
            let rollback = NetworkRollback {
                commands: vec![(
                    NMCLI_BIN.into(),
                    vec![
                        "connection".into(),
                        "up".into(),
                        "uuid".into(),
                        connection_uuid.to_string(),
                    ],
                )],
                restore_ipv4: Some(previous),
            };
            network_rollbacks.prepare(*configuration_id, rollback, Duration::from_secs(45))?;
            let mut apply_args = planned_args;
            apply_args[5] = connection_uuid.to_string();
            let modified = commands.run_appliance(NMCLI_BIN, apply_args, None)?;
            if !modified.success() {
                let restore_result = network_rollbacks.rollback(*configuration_id);
                if !matches!(restore_result, Ok(NetworkChangeResolution::Resolved)) {
                    return Err(BackendError::Failure(format!(
                        "NetworkManager rejected the manual IPv4 profile and the prior profile could not be restored: {restore_result:?}"
                    )));
                }
                return Err(BackendError::Failure(format!(
                    "NetworkManager rejected the manual IPv4 profile: {}",
                    modified.stderr_text()
                )));
            }
            let activated = commands.run_appliance(
                NMCLI_BIN,
                vec![
                    "--wait".into(),
                    "20".into(),
                    "connection".into(),
                    "up".into(),
                    "uuid".into(),
                    connection_uuid.to_string(),
                ],
                None,
            )?;
            if !activated.success() {
                let restore_result = network_rollbacks.rollback(*configuration_id);
                if !matches!(restore_result, Ok(NetworkChangeResolution::Resolved)) {
                    return Err(BackendError::Failure(format!(
                        "NetworkManager could not activate the manual IPv4 profile and the prior profile could not be restored: {restore_result:?}"
                    )));
                }
                return Err(BackendError::Failure(format!(
                    "NetworkManager could not activate the manual IPv4 profile: {}",
                    activated.stderr_text()
                )));
            }
            if let Err(error) = network_rollbacks.arm(*configuration_id, Duration::from_secs(30)) {
                let _ = network_rollbacks.rollback(*configuration_id);
                return Err(error);
            }
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "lan_ipv4_pending_confirmation".into(),
                message: "manual LAN IPv4 applied with automatic rollback".into(),
                details: serde_json::json!({
                    "configuration_id": configuration_id,
                    "candidate_address": address_with_prefix,
                    "auto_revert_seconds": 30,
                }),
            })
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
