use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    commands: appliance_commands::ApplianceCommands<'_>,
    network: network_inspection::NetworkInspection<'_>,
    network_rollbacks: &NetworkRollbackManager,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::ConfigureDirectEthernet { enabled, .. } => {
            let planned_args = if *enabled {
                vec![
                    "connection".into(),
                    "add".into(),
                    "type".into(),
                    "ethernet".into(),
                    "ifname".into(),
                    "<disconnected-ethernet-device>".into(),
                    "con-name".into(),
                    DIRECT_PROFILE.into(),
                    "ipv4.method".into(),
                    "link-local".into(),
                    "ipv6.method".into(),
                    "link-local".into(),
                ]
            } else {
                vec![
                    "connection".into(),
                    "delete".into(),
                    "id".into(),
                    DIRECT_PROFILE.into(),
                ]
            };
            if let Some(response) = commands.appliance_plan(
                request_id,
                "direct Ethernet plan approved",
                NMCLI_BIN,
                &planned_args,
                false,
            ) {
                return Ok(response);
            }
            let _network_mutation = network_rollbacks.begin_mutation()?;
            let existed = network.connection_exists(DIRECT_PROFILE)?;
            let was_active = network.connection_is_active(DIRECT_PROFILE)?;
            if *enabled && existed && was_active {
                // An existing profile still needs confirmation, even when no port selection or activation is required.
                network_rollbacks
                    .register_after_mutation(request_id, NetworkRollback::commands(Vec::new()))?;
            } else if *enabled {
                let interface = network.first_device_of_type("ethernet")?;
                if !existed {
                    let add_args = vec![
                        "connection".into(),
                        "add".into(),
                        "type".into(),
                        "ethernet".into(),
                        "ifname".into(),
                        interface.clone(),
                        "con-name".into(),
                        DIRECT_PROFILE.into(),
                        "connection.autoconnect".into(),
                        "yes".into(),
                        "ipv4.method".into(),
                        "link-local".into(),
                        "ipv6.method".into(),
                        "link-local".into(),
                    ];
                    let added = commands.run_appliance(NMCLI_BIN, add_args, None)?;
                    if !added.success() {
                        return Err(BackendError::Failure(format!(
                            "NetworkManager could not create the direct profile: {}",
                            added.stderr_text()
                        )));
                    }
                }
                let up_args = vec![
                    "connection".into(),
                    "up".into(),
                    "id".into(),
                    DIRECT_PROFILE.into(),
                    "ifname".into(),
                    interface,
                ];
                let activated = commands.run_appliance(NMCLI_BIN, up_args, None)?;
                if !activated.success() {
                    return Err(BackendError::Failure(format!(
                        "NetworkManager could not activate the direct profile: {}",
                        activated.stderr_text()
                    )));
                }
                let commands = if was_active {
                    Vec::new()
                } else if existed {
                    vec![(
                        NMCLI_BIN.into(),
                        vec![
                            "connection".into(),
                            "down".into(),
                            "id".into(),
                            DIRECT_PROFILE.into(),
                        ],
                    )]
                } else {
                    vec![(
                        NMCLI_BIN.into(),
                        vec![
                            "connection".into(),
                            "delete".into(),
                            "id".into(),
                            DIRECT_PROFILE.into(),
                        ],
                    )]
                };
                network_rollbacks
                    .register_after_mutation(request_id, NetworkRollback::commands(commands))?;
            } else if existed && was_active {
                let output = commands.run_appliance(
                    NMCLI_BIN,
                    vec![
                        "connection".into(),
                        "down".into(),
                        "id".into(),
                        DIRECT_PROFILE.into(),
                    ],
                    None,
                )?;
                if !output.success() {
                    return Err(BackendError::Failure(format!(
                        "NetworkManager could not disable the direct profile: {}",
                        output.stderr_text()
                    )));
                }
                network_rollbacks.register_after_mutation(
                    request_id,
                    NetworkRollback::commands(vec![(
                        NMCLI_BIN.into(),
                        vec![
                            "connection".into(),
                            "up".into(),
                            "id".into(),
                            DIRECT_PROFILE.into(),
                        ],
                    )]),
                )?;
            }
            Ok(PrivilegedResponse::ok(
                request_id,
                if *enabled {
                    "direct_ethernet_enabled"
                } else {
                    "direct_ethernet_disabled"
                },
                "direct Ethernet setting applied",
            ))
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
