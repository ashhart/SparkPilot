use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    commands: appliance_commands::ApplianceCommands<'_>,
    network: network_inspection::NetworkInspection<'_>,
    network_rollbacks: &NetworkRollbackManager,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::ConfigureTravelAccessPoint {
            configuration_id,
            enabled,
            ssid,
            passphrase,
            ..
        } => {
            if *enabled {
                let Some(ssid) = ssid.as_deref() else {
                    return Err(BackendError::InvalidInput(
                        "travel access point requires an SSID".into(),
                    ));
                };
                let Some(passphrase) = passphrase.as_ref() else {
                    return Err(BackendError::InvalidInput(
                        "travel access point requires a passphrase".into(),
                    ));
                };
                if !valid_ssid(ssid) || !valid_wifi_passphrase(passphrase.expose_secret(), 12) {
                    return Err(BackendError::InvalidInput(
                        "travel access point credentials fail the WPA policy".into(),
                    ));
                }
                let args = vec![
                    "--ask".into(),
                    "--wait".into(),
                    "90".into(),
                    "connection".into(),
                    "up".into(),
                    "id".into(),
                    TRAVEL_PROFILE.into(),
                ];
                if let Some(response) = commands.appliance_plan(
                    request_id,
                    "travel access point plan approved",
                    NMCLI_BIN,
                    &args,
                    true,
                ) {
                    return Ok(response);
                }
                let _network_mutation = network_rollbacks.begin_mutation()?;
                let previous_wifi = network.active_wifi_uuid()?;
                let interface = network.first_device_of_type("wifi")?;
                let _ = commands.run_appliance(
                    NMCLI_BIN,
                    vec![
                        "connection".into(),
                        "delete".into(),
                        "id".into(),
                        TRAVEL_PROFILE.into(),
                    ],
                    None,
                );
                let added = commands.run_appliance(
                    NMCLI_BIN,
                    vec![
                        "connection".into(),
                        "add".into(),
                        "type".into(),
                        "wifi".into(),
                        "ifname".into(),
                        interface,
                        "con-name".into(),
                        TRAVEL_PROFILE.into(),
                        "ssid".into(),
                        ssid.into(),
                        "802-11-wireless.mode".into(),
                        "ap".into(),
                        "ipv4.method".into(),
                        "shared".into(),
                        "ipv6.method".into(),
                        "disabled".into(),
                        "802-11-wireless-security.key-mgmt".into(),
                        "sae".into(),
                        "802-11-wireless-security.pmf".into(),
                        "2".into(),
                    ],
                    None,
                )?;
                if !added.success() {
                    return Err(BackendError::Failure(format!(
                        "NetworkManager could not create the WPA3 travel profile: {}",
                        added.stderr_text()
                    )));
                }
                let output =
                    commands.run_appliance(NMCLI_BIN, args, Some(passphrase.expose_secret()))?;
                if !output.success() {
                    let _ = commands.run_appliance(
                        NMCLI_BIN,
                        vec![
                            "connection".into(),
                            "delete".into(),
                            "id".into(),
                            TRAVEL_PROFILE.into(),
                        ],
                        None,
                    );
                    if let Some(previous_wifi) = previous_wifi.as_ref() {
                        let _ = commands.run_appliance(
                            NMCLI_BIN,
                            vec![
                                "connection".into(),
                                "up".into(),
                                "uuid".into(),
                                previous_wifi.clone(),
                            ],
                            None,
                        );
                    }
                    return Err(BackendError::Failure(format!(
                        "NetworkManager could not start the travel access point: {}",
                        output.stderr_text()
                    )));
                }
                let mut commands = vec![(
                    NMCLI_BIN.into(),
                    vec![
                        "connection".into(),
                        "delete".into(),
                        "id".into(),
                        TRAVEL_PROFILE.into(),
                    ],
                )];
                if let Some(previous_wifi) = previous_wifi {
                    commands.push((
                        NMCLI_BIN.into(),
                        vec![
                            "connection".into(),
                            "up".into(),
                            "uuid".into(),
                            previous_wifi,
                        ],
                    ));
                }
                network_rollbacks.register_after_mutation(
                    *configuration_id,
                    NetworkRollback::commands(commands),
                )?;
            } else {
                let args = vec![
                    "connection".into(),
                    "delete".into(),
                    "id".into(),
                    TRAVEL_PROFILE.into(),
                ];
                if let Some(response) = commands.appliance_plan(
                    request_id,
                    "travel access point disable plan approved",
                    NMCLI_BIN,
                    &args,
                    false,
                ) {
                    return Ok(response);
                }
                let _network_mutation = network_rollbacks.begin_mutation()?;
                let _ = commands.run_appliance(NMCLI_BIN, args, None)?;
            }
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: if *enabled {
                    "travel_ap_enabled".into()
                } else {
                    "travel_ap_disabled".into()
                },
                message: "travel access point setting applied".into(),
                details: serde_json::json!({ "configuration_id": configuration_id }),
            })
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
