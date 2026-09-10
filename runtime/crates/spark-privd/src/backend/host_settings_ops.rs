use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    commands: appliance_commands::ApplianceCommands<'_>,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::ConfigureBluetooth {
            action,
            device_address,
            ..
        } => {
            let requires_address =
                matches!(action, BluetoothAction::Pair | BluetoothAction::Remove);
            if requires_address
                && !device_address
                    .as_deref()
                    .is_some_and(valid_bluetooth_address)
            {
                return Err(BackendError::InvalidInput(
                    "Bluetooth pair/remove requires a valid device address".into(),
                ));
            }
            if !requires_address && device_address.is_some() {
                return Err(BackendError::InvalidInput(
                    "Bluetooth device address is not valid for this action".into(),
                ));
            }
            let (program, args) = match action {
                BluetoothAction::PowerOn => {
                    (RFKILL_BIN, vec!["unblock".into(), "bluetooth".into()])
                }
                BluetoothAction::PowerOff => (RFKILL_BIN, vec!["block".into(), "bluetooth".into()]),
                BluetoothAction::StartDiscovery => (
                    BLUETOOTHCTL_BIN,
                    vec!["--timeout".into(), "15".into(), "scan".into(), "on".into()],
                ),
                BluetoothAction::StopDiscovery => {
                    (BLUETOOTHCTL_BIN, vec!["scan".into(), "off".into()])
                }
                BluetoothAction::Pair => (
                    BLUETOOTHCTL_BIN,
                    vec![
                        "pair".into(),
                        device_address.clone().expect("validated address"),
                    ],
                ),
                BluetoothAction::Remove => (
                    BLUETOOTHCTL_BIN,
                    vec![
                        "remove".into(),
                        device_address.clone().expect("validated address"),
                    ],
                ),
            };
            if let Some(response) = commands.appliance_plan(
                request_id,
                "Bluetooth plan approved",
                program,
                &args,
                false,
            ) {
                return Ok(response);
            }
            let output = commands.run_appliance(program, args, None)?;
            if !output.success() {
                return Err(BackendError::Failure(format!(
                    "Bluetooth action failed: {}",
                    output.stderr_text()
                )));
            }
            Ok(PrivilegedResponse::ok(
                request_id,
                "bluetooth_updated",
                "Bluetooth setting applied",
            ))
        }
        PrivilegedOperation::SetPowerProfile { mode_id, .. } => {
            if *mode_id >= crate::cpu_power::AUTOMATIC {
                if ![
                    crate::cpu_power::AUTOMATIC,
                    crate::cpu_power::COOLER,
                    crate::cpu_power::QUIET,
                ]
                .contains(mode_id)
                {
                    return Err(BackendError::InvalidInput(
                        "Unsupported CPU cooling setting".into(),
                    ));
                }
                if commands.plan_only {
                    return Ok(PrivilegedResponse::ok(
                        request_id,
                        "planned",
                        "CPU ceiling plan approved",
                    ));
                }
                let policies = crate::cpu_power::apply(
                    Path::new(crate::cpu_power::POLICY_ROOT),
                    Path::new(crate::cpu_power::STATE_PATH),
                    *mode_id,
                )
                .map_err(BackendError::Failure)?;
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "cpu_ceiling_changed".into(),
                    message: "CPU frequency ceilings applied".into(),
                    details: serde_json::json!({"policies":policies}),
                });
            }
            let args = vec!["-m".into(), mode_id.to_string()];
            if let Some(response) = commands.appliance_plan(
                request_id,
                "power profile plan approved",
                NVPMODEL_BIN,
                &args,
                false,
            ) {
                return Ok(response);
            }
            let output = commands.run_appliance(NVPMODEL_BIN, args, None)?;
            if !output.success() {
                return Err(BackendError::Failure(format!(
                    "nvpmodel rejected the power profile: {}",
                    output.stderr_text()
                )));
            }
            Ok(PrivilegedResponse::ok(
                request_id,
                "power_profile_changed",
                "power profile applied",
            ))
        }
        PrivilegedOperation::ConfigureSystemTime {
            timezone,
            ntp_enabled,
            ..
        } => {
            if !valid_timezone(timezone) {
                return Err(BackendError::InvalidInput(
                    "timezone must be a valid Area/Location identifier".into(),
                ));
            }
            let timezone_args = vec!["set-timezone".into(), timezone.clone()];
            if let Some(response) = commands.appliance_plan(
                request_id,
                "time and locale plan approved",
                TIMEDATECTL_BIN,
                &timezone_args,
                false,
            ) {
                return Ok(response);
            }
            for args in [
                timezone_args,
                vec![
                    "set-ntp".into(),
                    if *ntp_enabled {
                        "true".into()
                    } else {
                        "false".into()
                    },
                ],
            ] {
                let output = commands.run_appliance(TIMEDATECTL_BIN, args, None)?;
                if !output.success() {
                    return Err(BackendError::Failure(format!(
                        "time configuration failed: {}",
                        output.stderr_text()
                    )));
                }
            }
            Ok(PrivilegedResponse::ok(
                request_id,
                "system_time_configured",
                "time and NTP settings applied",
            ))
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
