use super::*;

pub(super) async fn bluetooth_status() -> BluetoothStatus {
    let Some(controller) = fixed_output("bluetoothctl", &["show"]).await else {
        return BluetoothStatus::default();
    };
    let powered = controller
        .lines()
        .any(|line| line.trim().eq_ignore_ascii_case("Powered: yes"));
    let discovering = controller
        .lines()
        .any(|line| line.trim().eq_ignore_ascii_case("Discovering: yes"));
    let paired = bluetooth_addresses("Paired").await;
    let connected = bluetooth_addresses("Connected").await;
    let devices = fixed_output("bluetoothctl", &["devices"])
        .await
        .unwrap_or_default()
        .lines()
        .filter_map(|line| {
            let rest = line.strip_prefix("Device ")?;
            let (address, name) = rest.split_once(' ')?;
            Some(BluetoothDeviceStatus {
                address: address.to_owned(),
                name: name.to_owned(),
                paired: paired.contains(address),
                connected: connected.contains(address),
            })
        })
        .collect();
    BluetoothStatus {
        available: true,
        powered,
        discovering,
        nearby_devices: devices,
    }
}

pub(super) async fn bluetooth_addresses(filter: &str) -> HashSet<String> {
    fixed_output("bluetoothctl", &["devices", filter])
        .await
        .unwrap_or_default()
        .lines()
        .filter_map(|line| line.strip_prefix("Device "))
        .filter_map(|line| line.split_once(' ').map(|(address, _)| address.to_owned()))
        .collect()
}

pub(super) async fn power_profile_status() -> PowerProfileStatus {
    let Some(query) = fixed_output("nvpmodel", &["-q"]).await else {
        let Ok(policies) =
            spark_privd::cpu_power::policies(Path::new(spark_privd::cpu_power::POLICY_ROOT))
        else {
            return PowerProfileStatus::default();
        };
        let modes = vec![
            PowerProfileMode {
                mode_id: 200,
                name: "CPU Automatic".into(),
            },
            PowerProfileMode {
                mode_id: 201,
                name: "CPU Cooler".into(),
            },
            PowerProfileMode {
                mode_id: 202,
                name: "CPU Quiet".into(),
            },
        ];
        let current_mode_id = spark_privd::cpu_power::observed_mode(&policies);
        return PowerProfileStatus {
            available: true,
            current_mode_id,
            current_name: modes
                .iter()
                .find(|mode| Some(mode.mode_id) == current_mode_id)
                .map(|mode| mode.name.clone()),
            modes,
            ..Default::default()
        };
    };
    let current_name = query
        .lines()
        .map(str::trim)
        .find(|line| {
            !line.is_empty() && !line.starts_with("NV Power Mode") && line.parse::<u8>().is_err()
        })
        .map(str::to_owned);
    let current_mode_id = query
        .lines()
        .map(str::trim)
        .find_map(|line| line.parse::<u8>().ok());
    let config = tokio::fs::read_to_string("/etc/nvpmodel.conf")
        .await
        .unwrap_or_default();
    let mut modes = Vec::new();
    for line in config.lines().filter(|line| line.contains("POWER_MODEL")) {
        let id = field_after(line, "ID=").and_then(|value| value.parse::<u8>().ok());
        let name = field_after(line, "NAME=");
        if let (Some(mode_id), Some(name)) = (id, name)
            && !modes
                .iter()
                .any(|mode: &PowerProfileMode| mode.mode_id == mode_id)
        {
            modes.push(PowerProfileMode { mode_id, name });
        }
    }
    modes.sort_by_key(|mode| mode.mode_id);
    PowerProfileStatus {
        available: true,
        current_mode_id,
        current_name,
        modes,
        reboot_required: false,
        temperature_celsius: None,
        power_draw_watts: None,
        power_limit_watts: None,
    }
}

pub(super) fn field_after(line: &str, marker: &str) -> Option<String> {
    let value = line.split_once(marker)?.1;
    let value = value
        .split(|character: char| character.is_whitespace() || character == '>')
        .next()?;
    (!value.is_empty()).then(|| value.to_owned())
}

pub(super) async fn software_update_status(observed_at: &str) -> SoftwareUpdateStatus {
    let system_packages_available =
        fixed_output("apt-get", &["-s", "dist-upgrade"])
            .await
            .map(|output| {
                output
                    .lines()
                    .filter(|line| line.starts_with("Inst "))
                    .count() as u64
            });
    let firmware_updates_available =
        fixed_output_with_status("fwupdmgr", &["get-updates", "--json"], &[0, 2])
            .await
            .and_then(|output| {
                if output.trim().is_empty() {
                    return Some(0);
                }
                let value = serde_json::from_str::<Value>(&output).ok()?;
                value
                    .get("Devices")
                    .or_else(|| value.get("devices"))
                    .and_then(Value::as_array)
                    .map(|devices| devices.len() as u64)
            });
    SoftwareUpdateStatus {
        checked_at: observed_at.to_owned(),
        system_packages_available,
        firmware_updates_available,
        runtime_release_id: staged_runtime_release(),
        reboot_required: Path::new("/var/run/reboot-required").exists(),
    }
}

pub(super) fn staged_runtime_release() -> Option<String> {
    use spark_privd::update::{
        DEFAULT_STAGING_ROOT, STAGED_MANIFEST, STAGED_PACKAGE, STAGED_SIGNATURE,
        validate_release_id,
    };

    let mut releases = std::fs::read_dir(DEFAULT_STAGING_ROOT)
        .ok()?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let metadata = std::fs::symlink_metadata(entry.path()).ok()?;
            if !metadata.is_dir() || metadata.file_type().is_symlink() {
                return None;
            }
            let release_id = entry.file_name().into_string().ok()?;
            validate_release_id(&release_id).ok()?;
            [STAGED_MANIFEST, STAGED_PACKAGE, STAGED_SIGNATURE]
                .into_iter()
                .all(|name| {
                    std::fs::symlink_metadata(entry.path().join(name))
                        .is_ok_and(|item| item.is_file() && !item.file_type().is_symlink())
                })
                .then_some(release_id)
        })
        .collect::<Vec<_>>();
    releases.sort();
    releases.pop()
}

pub(super) async fn system_time_status() -> SystemTimeStatus {
    let Some(output) = fixed_output(
        "timedatectl",
        &[
            "show",
            "--property=Timezone",
            "--property=NTP",
            "--property=NTPSynchronized",
        ],
    )
    .await
    else {
        return SystemTimeStatus::default();
    };
    let values = output
        .lines()
        .filter_map(|line| line.split_once('='))
        .collect::<HashMap<_, _>>();
    SystemTimeStatus {
        timezone: values.get("Timezone").copied().unwrap_or("Etc/UTC").into(),
        ntp_enabled: values.get("NTP").is_some_and(|value| *value == "yes"),
        synchronized: values
            .get("NTPSynchronized")
            .is_some_and(|value| *value == "yes"),
    }
}

pub(super) async fn docker_storage() -> (u64, u64) {
    let Some(output) = fixed_output(
        "docker",
        &[
            "system",
            "df",
            "--format",
            "{{.Type}}|{{.Size}}|{{.Reclaimable}}",
        ],
    )
    .await
    else {
        return (0, 0);
    };
    output.lines().fold((0_u64, 0_u64), |mut totals, line| {
        let mut fields = line.split('|');
        let _ = fields.next();
        totals.0 = totals
            .0
            .saturating_add(fields.next().and_then(parse_human_bytes).unwrap_or(0));
        totals.1 = totals
            .1
            .saturating_add(fields.next().and_then(parse_human_bytes).unwrap_or(0));
        totals
    })
}

pub(super) fn parse_human_bytes(raw: &str) -> Option<u64> {
    let value = raw.split_whitespace().next()?.trim_end_matches(['(', ')']);
    let split = value
        .char_indices()
        .find(|(_, character)| !character.is_ascii_digit() && *character != '.')
        .map(|(index, _)| index)
        .unwrap_or(value.len());
    let number = value[..split].parse::<f64>().ok()?;
    let unit = value[split..].trim().to_ascii_lowercase();
    let multiplier = match unit.as_str() {
        "b" | "" => 1_f64,
        "kb" => 1_000_f64,
        "mb" => 1_000_000_f64,
        "gb" => 1_000_000_000_f64,
        "tb" => 1_000_000_000_000_f64,
        "kib" => 1_024_f64,
        "mib" => 1_048_576_f64,
        "gib" => 1_073_741_824_f64,
        "tib" => 1_099_511_627_776_f64,
        _ => return None,
    };
    Some((number * multiplier).round() as u64)
}
