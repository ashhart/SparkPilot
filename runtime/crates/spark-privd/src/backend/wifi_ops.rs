use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    plan_only: bool,
    commands: appliance_commands::ApplianceCommands<'_>,
    network: network_inspection::NetworkInspection<'_>,
    network_rollbacks: &NetworkRollbackManager,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::ConnectWifi {
            ssid,
            passphrase,
            hidden,
            ..
        } => {
            if !valid_ssid(ssid) {
                return Err(BackendError::InvalidInput(
                    "Wi-Fi SSID must contain 1 to 32 non-control bytes".into(),
                ));
            }
            if passphrase
                .as_ref()
                .is_some_and(|secret| !valid_wifi_passphrase(secret.expose_secret(), 8))
            {
                return Err(BackendError::InvalidInput(
                    "Wi-Fi passphrase must contain 8 to 63 printable ASCII characters".into(),
                ));
            }
            let mut args = vec![
                "--wait".into(),
                "90".into(),
                "device".into(),
                "wifi".into(),
                "connect".into(),
                ssid.clone(),
            ];
            if *hidden {
                args.extend(["hidden".into(), "yes".into()]);
            }
            if passphrase.is_some() {
                args.insert(0, "--ask".into());
            }
            if let Some(response) = commands.appliance_plan(
                request_id,
                "Wi-Fi connection plan approved",
                NMCLI_BIN,
                &args,
                passphrase.is_some(),
            ) {
                return Ok(response);
            }
            let _network_mutation = network_rollbacks.begin_mutation()?;
            let previous_wifi = network.active_wifi_uuid()?;
            let target_was_saved = network.connection_exists(ssid)?;
            let output = commands.run_appliance(
                NMCLI_BIN,
                args,
                passphrase.as_ref().map(|secret| secret.expose_secret()),
            )?;
            if !output.success() {
                let detail = output.stderr_text();
                let lowered = detail.to_ascii_lowercase();
                if lowered.contains("secret")
                    || lowered.contains("password")
                    || lowered.contains("authentication")
                {
                    return Ok(PrivilegedResponse::rejected(
                        request_id,
                        "NETWORK_AUTHENTICATION_FAILED",
                        "The Wi-Fi password was rejected.",
                    ));
                }
                return Err(BackendError::Failure(format!(
                    "NetworkManager could not activate the Wi-Fi network: {detail}"
                )));
            }
            let mut commands = Vec::new();
            if !target_was_saved {
                commands.push((
                    NMCLI_BIN.into(),
                    vec![
                        "connection".into(),
                        "delete".into(),
                        "id".into(),
                        ssid.clone(),
                    ],
                ));
            }
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
            network_rollbacks
                .register_after_mutation(request_id, NetworkRollback::commands(commands))?;
            Ok(PrivilegedResponse::ok(
                request_id,
                "wifi_connected",
                "Wi-Fi network activated",
            ))
        }
        PrivilegedOperation::ForgetWifi { ssid, .. } => {
            if !valid_ssid(ssid) {
                return Err(BackendError::InvalidInput(
                    "Wi-Fi SSID must contain 1 to 32 non-control bytes".into(),
                ));
            }
            // Verify Wi-Fi type before deleting by name because nmcli can otherwise remove wired or VPN profiles.
            if !plan_only {
                network.ensure_wifi_profile(ssid)?;
            }
            let args = vec![
                "connection".into(),
                "delete".into(),
                "id".into(),
                ssid.clone(),
            ];
            if let Some(response) = commands.appliance_plan(
                request_id,
                "Wi-Fi forget plan approved",
                NMCLI_BIN,
                &args,
                false,
            ) {
                return Ok(response);
            }
            let _network_mutation = network_rollbacks.begin_mutation()?;
            let output = commands.run_appliance(NMCLI_BIN, args, None)?;
            if !output.success() {
                return Err(BackendError::Failure(format!(
                    "NetworkManager could not forget the Wi-Fi network: {}",
                    output.stderr_text()
                )));
            }
            Ok(PrivilegedResponse::ok(
                request_id,
                "wifi_forgotten",
                "Wi-Fi profile removed",
            ))
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
