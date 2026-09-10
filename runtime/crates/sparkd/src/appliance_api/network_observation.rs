use super::*;

pub(super) async fn network_feature_status() -> (bool, TravelAccessPointStatus) {
    let output = fixed_output(
        "nmcli",
        &[
            "--terse",
            "--escape",
            "yes",
            "--fields",
            "NAME,TYPE",
            "connection",
            "show",
            "--active",
        ],
    )
    .await
    .unwrap_or_default();
    let active = output
        .lines()
        .filter_map(|line| split_escaped(line, ':').first().cloned())
        .collect::<HashSet<_>>();
    let travel_enabled = active.contains("SparkPilot-Travel");
    let ssid = if travel_enabled {
        fixed_output(
            "nmcli",
            &[
                "--get-values",
                "802-11-wireless.ssid",
                "connection",
                "show",
                "SparkPilot-Travel",
            ],
        )
        .await
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
    } else {
        None
    };
    (
        active.contains("SparkPilot-Direct"),
        TravelAccessPointStatus {
            enabled: travel_enabled,
            ssid,
            security: if travel_enabled {
                "wpa3"
            } else {
                "unavailable"
            }
            .into(),
            auto_revert_seconds: 90,
        },
    )
}

pub(super) async fn wifi_scan() -> Vec<WifiNetwork> {
    let saved = fixed_output(
        "nmcli",
        &[
            "--terse",
            "--escape",
            "yes",
            "--get-values",
            "802-11-wireless.ssid",
            "connection",
            "show",
        ],
    )
    .await
    .unwrap_or_default()
    .lines()
    .map(unescape_nmcli)
    .filter(|value| !value.is_empty())
    .collect::<HashSet<_>>();
    let output = fixed_output(
        "nmcli",
        &[
            "--terse",
            "--escape",
            "yes",
            "--fields",
            "IN-USE,SSID,SIGNAL,SECURITY",
            "device",
            "wifi",
            "list",
            "--rescan",
            "auto",
        ],
    )
    .await
    .unwrap_or_default();
    let mut by_ssid = HashMap::<String, WifiNetwork>::new();
    for line in output.lines() {
        let fields = split_escaped(line, ':');
        if fields.len() < 4 || fields[1].is_empty() {
            continue;
        }
        let ssid = fields[1].clone();
        let signal = fields[2].parse::<u8>().unwrap_or(0).min(100);
        let network = WifiNetwork {
            ssid: ssid.clone(),
            security: wifi_security(&fields[3]).into(),
            signal_percent: signal,
            connected: fields[0] == "*" || fields[0].eq_ignore_ascii_case("yes"),
            saved: saved.contains(&ssid),
        };
        let replace = by_ssid
            .get(&ssid)
            .is_none_or(|existing| network.connected || signal > existing.signal_percent);
        if replace {
            by_ssid.insert(ssid, network);
        }
    }
    let mut networks = by_ssid.into_values().collect::<Vec<_>>();
    networks.sort_by(|left, right| {
        right
            .connected
            .cmp(&left.connected)
            .then(right.signal_percent.cmp(&left.signal_percent))
            .then(left.ssid.cmp(&right.ssid))
    });
    networks
}

pub(super) fn wifi_security(raw: &str) -> &'static str {
    let upper = raw.to_ascii_uppercase();
    if upper.contains("802.1X") || upper.contains("EAP") {
        "enterprise"
    } else if upper.contains("WPA3") || upper.contains("SAE") {
        "wpa3"
    } else if upper.contains("WPA") {
        "wpa2"
    } else if upper.is_empty() || upper == "--" {
        "open"
    } else {
        "unknown"
    }
}

pub(super) fn split_escaped(input: &str, separator: char) -> Vec<String> {
    let mut fields = Vec::new();
    let mut field = String::new();
    let mut escaped = false;
    for character in input.chars() {
        if escaped {
            field.push(character);
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else if character == separator {
            fields.push(std::mem::take(&mut field));
        } else {
            field.push(character);
        }
    }
    if escaped {
        field.push('\\');
    }
    fields.push(field);
    fields
}

pub(super) fn unescape_nmcli(input: &str) -> String {
    split_escaped(input, '\0')
        .into_iter()
        .next()
        .unwrap_or_default()
}
