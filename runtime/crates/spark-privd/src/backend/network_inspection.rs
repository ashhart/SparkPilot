use super::*;

pub(super) struct NetworkInspection<'a> {
    pub(super) network_sysfs_root: &'a Path,
    pub(super) commands: appliance_commands::ApplianceCommands<'a>,
}

impl NetworkInspection<'_> {
    /// Refuse a NetworkManager profile that is not a Wi-Fi network.
    pub(super) fn ensure_wifi_profile(&self, ssid: &str) -> Result<(), BackendError> {
        let output = self.commands.run_appliance(
            NMCLI_BIN,
            vec![
                "-g".into(),
                "connection.type".into(),
                "connection".into(),
                "show".into(),
                "id".into(),
                ssid.to_owned(),
            ],
            None,
        )?;
        if !output.success() {
            return Err(BackendError::InvalidInput(
                "no saved Wi-Fi network has that name".into(),
            ));
        }
        if String::from_utf8_lossy(&output.stdout).trim() != "802-11-wireless" {
            return Err(BackendError::InvalidInput(
                "that connection profile is not a Wi-Fi network".into(),
            ));
        }
        Ok(())
    }

    pub(super) fn first_device_of_type(&self, device_type: &str) -> Result<String, BackendError> {
        let args = vec![
            "--terse".to_owned(),
            "--fields".to_owned(),
            "DEVICE,TYPE,STATE".to_owned(),
            "device".to_owned(),
            "status".to_owned(),
        ];
        let output = self.commands.run_appliance(NMCLI_BIN, args, None)?;
        if !output.success() {
            return Err(BackendError::Failure(format!(
                "NetworkManager device query failed: {}",
                output.stderr_text()
            )));
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let devices = text
            .lines()
            .filter_map(|line| {
                let mut fields = line.splitn(3, ':');
                Some((fields.next()?, fields.next()?, fields.next()?))
            })
            .filter(|(name, kind, _)| {
                *kind != "ethernet" || !self.protected_network_interface(name)
            })
            .collect::<Vec<_>>();
        if device_type == "ethernet" {
            // Select only disconnected Ethernet ports to preserve management connectivity.
            return devices
                .iter()
                .find(|(_, kind, state)| *kind == "ethernet" && *state == "disconnected")
                .map(|(name, _, _)| (*name).to_owned())
                .ok_or_else(|| {
                    BackendError::Failure(
                        "no disconnected Ethernet port is available; use an unused ordinary Ethernet port for the direct link and keep the management LAN connected"
                            .into(),
                    )
                });
        }
        devices
            .iter()
            .find(|(_, kind, state)| {
                *kind == device_type && !matches!(*state, "unavailable" | "unmanaged" | "connected")
            })
            .or_else(|| devices.iter().find(|(_, kind, _)| *kind == device_type))
            .map(|(name, _, _)| (*name).to_owned())
            .ok_or_else(|| BackendError::Failure(format!("no {device_type} device is available")))
    }

    pub(super) fn protected_network_interface(&self, name: &str) -> bool {
        let valid_name = !name.is_empty()
            && name.len() < libc::IF_NAMESIZE
            && name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'));
        if !valid_name
            || name == "lo"
            || [
                "br-",
                "cni",
                "docker",
                "flannel",
                "tailscale",
                "tap",
                "tun",
                "veth",
                "virbr",
                "wg",
                "zt",
            ]
            .iter()
            .any(|prefix| name.starts_with(prefix))
        {
            return true;
        }
        fs::read_to_string(self.network_sysfs_root.join(name).join("device/vendor"))
            .is_ok_and(|vendor| vendor.trim().eq_ignore_ascii_case("0x15b3"))
    }

    pub(super) fn active_lan_connection(&self) -> Result<(uuid::Uuid, String), BackendError> {
        let output = self.commands.run_appliance(
            NMCLI_BIN,
            vec![
                "--terse".into(),
                "--escape".into(),
                "no".into(),
                "--fields".into(),
                "UUID,TYPE,DEVICE".into(),
                "connection".into(),
                "show".into(),
                "--active".into(),
            ],
            None,
        )?;
        if !output.success() {
            return Err(BackendError::Failure(
                "NetworkManager could not resolve the active LAN connection".into(),
            ));
        }
        let candidates = String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter_map(|line| {
                let mut fields = line.splitn(3, ':');
                let connection_uuid = uuid::Uuid::parse_str(fields.next()?).ok()?;
                let connection_type = fields.next()?;
                let device = fields.next()?;
                matches!(connection_type, "ethernet" | "802-3-ethernet")
                    .then_some((connection_uuid, device.to_owned()))
            })
            .filter(|(_, device)| !self.protected_network_interface(device))
            .collect::<Vec<_>>();
        match candidates.as_slice() {
            [(connection_uuid, device)] => Ok((*connection_uuid, device.clone())),
            [] => Err(BackendError::Failure(
                "no active ordinary LAN connection is available".into(),
            )),
            _ => Err(BackendError::Failure(
                "more than one ordinary LAN connection is active; choose a single management route first"
                    .into(),
            )),
        }
    }

    pub(super) fn snapshot_lan_ipv4(
        &self,
        connection_uuid: uuid::Uuid,
    ) -> Result<StoredIpv4Configuration, BackendError> {
        let output = self.commands.run_appliance(
            NMCLI_BIN,
            vec![
                "--terse".into(),
                "--escape".into(),
                "no".into(),
                "--fields".into(),
                "ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns,ipv4.ignore-auto-dns".into(),
                "connection".into(),
                "show".into(),
                "uuid".into(),
                connection_uuid.to_string(),
            ],
            None,
        )?;
        if !output.success() {
            return Err(BackendError::Failure(
                "NetworkManager could not snapshot the active LAN profile".into(),
            ));
        }
        let mut fields = HashMap::new();
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            if let Some((key, value)) = line.split_once(':') {
                fields.insert(key.trim().to_ascii_lowercase(), value.trim().to_owned());
            }
        }
        let method = match fields.get("ipv4.method").map(String::as_str) {
            Some("auto") => StoredIpv4Method::Auto,
            Some("manual") => StoredIpv4Method::Manual,
            Some("disabled") => StoredIpv4Method::Disabled,
            Some("link-local") => StoredIpv4Method::LinkLocal,
            _ => {
                return Err(BackendError::Failure(
                    "the active LAN profile uses an unsupported IPv4 mode".into(),
                ));
            }
        };
        let addresses = parse_stored_ipv4_addresses(
            fields
                .get("ipv4.addresses")
                .map(String::as_str)
                .unwrap_or(""),
        )?;
        let gateway =
            parse_optional_ipv4(fields.get("ipv4.gateway").map(String::as_str).unwrap_or(""))?;
        let dns_servers =
            parse_ipv4_list(fields.get("ipv4.dns").map(String::as_str).unwrap_or(""))?;
        let ignore_auto_dns = match fields.get("ipv4.ignore-auto-dns").map(String::as_str) {
            Some("yes" | "true") => true,
            Some("no" | "false") => false,
            _ => {
                return Err(BackendError::Failure(
                    "the active LAN profile has an invalid DNS policy".into(),
                ));
            }
        };
        let configuration = StoredIpv4Configuration {
            connection_uuid,
            method,
            addresses,
            gateway,
            dns_servers,
            ignore_auto_dns,
        };
        valid_stored_ipv4(&configuration)
            .then_some(configuration)
            .ok_or_else(|| {
                BackendError::Failure(
                    "the active LAN profile cannot be represented by the rollback journal".into(),
                )
            })
    }

    pub(super) fn active_wifi_uuid(&self) -> Result<Option<String>, BackendError> {
        let output = self.commands.run_appliance(
            NMCLI_BIN,
            vec![
                "--terse".into(),
                "--fields".into(),
                "UUID,TYPE".into(),
                "connection".into(),
                "show".into(),
                "--active".into(),
            ],
            None,
        )?;
        if !output.success() {
            return Err(BackendError::Failure(
                "NetworkManager could not snapshot the active Wi-Fi connection".into(),
            ));
        }
        Ok(String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter_map(|line| line.split_once(':'))
            .find(|(_, kind)| matches!(*kind, "wifi" | "802-11-wireless"))
            .map(|(uuid, _)| uuid.to_owned()))
    }

    pub(super) fn connection_exists(&self, name: &str) -> Result<bool, BackendError> {
        let output = self.commands.run_appliance(
            NMCLI_BIN,
            vec![
                "--get-values".into(),
                "UUID".into(),
                "connection".into(),
                "show".into(),
                "id".into(),
                name.into(),
            ],
            None,
        )?;
        Ok(output.success() && !String::from_utf8_lossy(&output.stdout).trim().is_empty())
    }

    pub(super) fn connection_is_active(&self, name: &str) -> Result<bool, BackendError> {
        let output = self.commands.run_appliance(
            NMCLI_BIN,
            vec![
                "--get-values".into(),
                "UUID".into(),
                "connection".into(),
                "show".into(),
                "--active".into(),
                "id".into(),
                name.into(),
            ],
            None,
        )?;
        Ok(output.success() && !String::from_utf8_lossy(&output.stdout).trim().is_empty())
    }
}
