use super::*;

#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub(crate) struct StoredIpv4Configuration {
    pub(crate) connection_uuid: uuid::Uuid,
    pub(crate) method: StoredIpv4Method,
    pub(crate) addresses: Vec<StoredIpv4Address>,
    pub(crate) gateway: Option<Ipv4Addr>,
    pub(crate) dns_servers: Vec<Ipv4Addr>,
    pub(crate) ignore_auto_dns: bool,
}

#[derive(Clone, Copy, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum StoredIpv4Method {
    Auto,
    Manual,
    Disabled,
    LinkLocal,
}

impl StoredIpv4Method {
    pub(super) fn as_nmcli(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Manual => "manual",
            Self::Disabled => "disabled",
            Self::LinkLocal => "link-local",
        }
    }
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub(crate) struct StoredIpv4Address {
    pub(crate) address: Ipv4Addr,
    pub(crate) prefix_length: u8,
}

pub(super) fn valid_network_rollback(rollback: &NetworkRollback) -> bool {
    let commands_valid = rollback.commands.len() <= 2
        && rollback.commands.iter().all(|(program, arguments)| {
            if program != NMCLI_BIN || arguments.len() != 4 || arguments[0] != "connection" {
                return false;
            }
            match (arguments[1].as_str(), arguments[2].as_str()) {
                // Allow rollback of internal profiles while refusing them as Wi-Fi input.
                ("delete", "id") => {
                    matches!(arguments[3].as_str(), DIRECT_PROFILE | TRAVEL_PROFILE)
                        || valid_ssid(&arguments[3])
                }
                ("up", "uuid") => uuid::Uuid::parse_str(&arguments[3]).is_ok(),
                ("up" | "down", "id") => arguments[3] == DIRECT_PROFILE,
                _ => false,
            }
        });
    if !commands_valid {
        return false;
    }
    match &rollback.restore_ipv4 {
        None => true,
        Some(configuration) => {
            valid_stored_ipv4(configuration)
                && rollback.commands.len() == 1
                && rollback.commands[0].0 == NMCLI_BIN
                && rollback.commands[0].1
                    == [
                        "connection".to_owned(),
                        "up".to_owned(),
                        "uuid".to_owned(),
                        configuration.connection_uuid.to_string(),
                    ]
        }
    }
}

pub(crate) fn valid_stored_ipv4(configuration: &StoredIpv4Configuration) -> bool {
    if configuration.addresses.len() > 4
        || configuration.dns_servers.len() > 3
        || configuration
            .addresses
            .iter()
            .any(|value| !(1..=30).contains(&value.prefix_length) || !usable_host(value.address))
        || configuration
            .dns_servers
            .iter()
            .any(|value| value.is_unspecified() || value.is_multicast())
    {
        return false;
    }
    match configuration.method {
        StoredIpv4Method::Auto => {
            configuration.addresses.is_empty() && configuration.gateway.is_none()
        }
        StoredIpv4Method::Disabled | StoredIpv4Method::LinkLocal => {
            configuration.addresses.is_empty()
                && configuration.gateway.is_none()
                && configuration.dns_servers.is_empty()
        }
        StoredIpv4Method::Manual => {
            let Some(first) = configuration.addresses.first() else {
                return false;
            };
            configuration.gateway.is_none_or(|gateway| {
                usable_host(gateway) && same_subnet(first.address, gateway, first.prefix_length)
            })
        }
    }
}

pub(super) fn usable_host(address: Ipv4Addr) -> bool {
    !address.is_unspecified()
        && !address.is_loopback()
        && !address.is_link_local()
        && !address.is_multicast()
        && address != Ipv4Addr::BROADCAST
}

pub(super) fn same_subnet(left: Ipv4Addr, right: Ipv4Addr, prefix_length: u8) -> bool {
    let mask = u32::MAX << (32 - prefix_length);
    u32::from(left) & mask == u32::from(right) & mask
}
