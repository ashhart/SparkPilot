//! Read interface facts locally and mutate through typed helper operations; omit hardware and full network addresses from redacted status.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::Serialize;

/// One interface as the API reports it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct InterfaceStatus {
    pub name: String,
    /// `wired`, `wireless`, `loopback`, `virtual`, or `other`.
    pub kind: String,
    /// `up`, `down`, or `unknown` — the kernel's operational state.
    pub state: String,
    /// Report the presence of a routable address without disclosing it.
    pub has_global_address: bool,
}

/// The `GET /api/v1/network` document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct NetworkStatus {
    /// Identify sysfs evidence or explicit unavailability without invented readings.
    pub source: String,
    pub interfaces: Vec<InterfaceStatus>,
    /// Whether the product's direct-Ethernet fallback profile is configured.
    pub direct_profile: bool,
    /// Whether the product's travel access point is configured.
    pub travel_access_point: bool,
}

/// Where interface facts come from. Production reads sysfs; tests inject.
pub trait InterfaceSource: Send + Sync {
    fn interfaces(&self) -> Result<Vec<InterfaceStatus>, String>;
    /// Report the source name so callers can distinguish observed and unavailable data.
    fn name(&self) -> &'static str;
}

/// Linux `/sys/class/net` reader.
pub struct SysfsInterfaces {
    root: PathBuf,
}

impl Default for SysfsInterfaces {
    fn default() -> Self {
        Self {
            root: PathBuf::from("/sys/class/net"),
        }
    }
}

impl SysfsInterfaces {
    pub fn with_root(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn available(&self) -> bool {
        self.root.is_dir()
    }

    fn classify(directory: &Path, name: &str) -> String {
        if name == "lo" {
            return "loopback".to_owned();
        }
        if directory.join("wireless").exists() || directory.join("phy80211").exists() {
            return "wireless".to_owned();
        }
        // Treat interfaces without a backing device symlink as virtual rather than hardware ports.
        if !directory.join("device").exists() {
            return "virtual".to_owned();
        }
        match std::fs::read_to_string(directory.join("type"))
            .ok()
            .and_then(|value| value.trim().parse::<u32>().ok())
        {
            // ARPHRD_ETHER
            Some(1) => "wired".to_owned(),
            _ => "other".to_owned(),
        }
    }
}

impl InterfaceSource for SysfsInterfaces {
    fn name(&self) -> &'static str {
        "sysfs"
    }

    fn interfaces(&self) -> Result<Vec<InterfaceStatus>, String> {
        let entries = std::fs::read_dir(&self.root).map_err(|error| error.to_string())?;
        let mut interfaces = Vec::new();
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let directory = entry.path();
            let state = std::fs::read_to_string(directory.join("operstate"))
                .map(|value| value.trim().to_owned())
                .unwrap_or_else(|_| "unknown".to_owned());
            interfaces.push(InterfaceStatus {
                kind: SysfsInterfaces::classify(&directory, &name),
                // Require actual carrier so administrative up state alone cannot imply a connected address.
                has_global_address: std::fs::read_to_string(directory.join("carrier"))
                    .map(|value| value.trim() == "1")
                    .unwrap_or(false)
                    && name != "lo",
                name,
                state,
            });
        }
        interfaces.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(interfaces)
    }
}

/// Report unavailable interface observations on development hosts without sysfs.
pub struct UnavailableInterfaces;

impl InterfaceSource for UnavailableInterfaces {
    fn name(&self) -> &'static str {
        "unavailable"
    }

    fn interfaces(&self) -> Result<Vec<InterfaceStatus>, String> {
        Ok(Vec::new())
    }
}

/// The privileged boundary for network changes.
pub trait NetworkConfigurator: Send + Sync {
    fn configure_direct(&self, enabled: bool) -> Result<serde_json::Value, String>;
    /// Read active managed profiles from the helper; retain remembered state only when observation is unavailable.
    fn managed_profiles(&self) -> Option<(bool, bool)> {
        None
    }
    fn configure_travel_ap(
        &self,
        configuration_id: uuid::Uuid,
        enabled: bool,
        ssid: Option<&str>,
        passphrase: Option<&str>,
    ) -> Result<serde_json::Value, String>;
}

/// Production configurator: typed operations to `spark-privd`.
pub struct PrivilegedNetwork {
    client: crate::privd::PrivilegedClient,
}

impl PrivilegedNetwork {
    pub fn new(client: crate::privd::PrivilegedClient) -> Self {
        Self { client }
    }

    fn call(
        &self,
        operation: spark_privd::protocol::PrivilegedOperation,
    ) -> Result<serde_json::Value, String> {
        let response = self.client.call(operation).map_err(|e| e.to_string())?;
        if !response.accepted {
            return Err(format!("{}: {}", response.code, response.message));
        }
        Ok(response.details)
    }
}

impl NetworkConfigurator for PrivilegedNetwork {
    fn managed_profiles(&self) -> Option<(bool, bool)> {
        let details = self
            .call(
                spark_privd::protocol::PrivilegedOperation::ManagedNetworkProfiles {
                    request_id: uuid::Uuid::new_v4(),
                },
            )
            .ok()?;
        Some((
            details.get("direct_profile")?.as_bool()?,
            details.get("travel_access_point")?.as_bool()?,
        ))
    }

    fn configure_direct(&self, enabled: bool) -> Result<serde_json::Value, String> {
        self.call(
            spark_privd::protocol::PrivilegedOperation::ConfigureDirectEthernet {
                request_id: uuid::Uuid::new_v4(),
                enabled,
            },
        )
    }

    fn configure_travel_ap(
        &self,
        configuration_id: uuid::Uuid,
        enabled: bool,
        ssid: Option<&str>,
        passphrase: Option<&str>,
    ) -> Result<serde_json::Value, String> {
        self.call(
            spark_privd::protocol::PrivilegedOperation::ConfigureTravelAccessPoint {
                request_id: uuid::Uuid::new_v4(),
                configuration_id,
                enabled,
                ssid: ssid.map(str::to_owned),
                passphrase: passphrase.map(spark_privd::protocol::SecretString::new),
            },
        )
    }
}

/// Status reads plus the two configuration operations.
pub struct NetworkService {
    interfaces: Arc<dyn InterfaceSource>,
    configurator: Arc<dyn NetworkConfigurator>,
    /// Cache last-known profiles while treating helper observations as authoritative.
    direct_profile: parking_lot::Mutex<bool>,
    travel_access_point: parking_lot::Mutex<bool>,
}

impl NetworkService {
    pub fn new(
        interfaces: Arc<dyn InterfaceSource>,
        configurator: Arc<dyn NetworkConfigurator>,
    ) -> Self {
        Self {
            interfaces,
            configurator,
            direct_profile: parking_lot::Mutex::new(false),
            travel_access_point: parking_lot::Mutex::new(false),
        }
    }

    /// Use sysfs where present and explicit unavailability elsewhere.
    pub fn production(client: crate::privd::PrivilegedClient) -> Self {
        let sysfs = SysfsInterfaces::default();
        let interfaces: Arc<dyn InterfaceSource> = if sysfs.available() {
            Arc::new(sysfs)
        } else {
            tracing::info!("/sys/class/net is unavailable; network status reports no interfaces");
            Arc::new(UnavailableInterfaces)
        };
        Self::new(interfaces, Arc::new(PrivilegedNetwork::new(client)))
    }

    pub fn status(&self) -> Result<NetworkStatus, String> {
        // Prefer what the helper can see over what this process remembers.
        let (direct, travel) = match self.configurator.managed_profiles() {
            Some((direct, travel)) => {
                *self.direct_profile.lock() = direct;
                *self.travel_access_point.lock() = travel;
                (direct, travel)
            }
            None => (
                *self.direct_profile.lock(),
                *self.travel_access_point.lock(),
            ),
        };
        Ok(NetworkStatus {
            source: self.interfaces.name().to_owned(),
            interfaces: self.interfaces.interfaces()?,
            direct_profile: direct,
            travel_access_point: travel,
        })
    }

    pub fn configure_direct(&self, enabled: bool) -> Result<serde_json::Value, String> {
        let details = self.configurator.configure_direct(enabled)?;
        *self.direct_profile.lock() = enabled;
        Ok(details)
    }

    /// Return generated access-point credentials once for QR display without storing or logging them in this service.
    pub fn configure_travel_ap(
        &self,
        configuration_id: uuid::Uuid,
        enabled: bool,
        ssid: Option<&str>,
        passphrase: Option<&str>,
    ) -> Result<serde_json::Value, String> {
        let details =
            self.configurator
                .configure_travel_ap(configuration_id, enabled, ssid, passphrase)?;
        *self.travel_access_point.lock() = enabled;
        Ok(details)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct RecordingConfigurator;

    impl NetworkConfigurator for RecordingConfigurator {
        fn configure_direct(&self, enabled: bool) -> Result<serde_json::Value, String> {
            Ok(serde_json::json!({ "enabled": enabled }))
        }
        fn configure_travel_ap(
            &self,
            _configuration_id: uuid::Uuid,
            enabled: bool,
            _ssid: Option<&str>,
            _passphrase: Option<&str>,
        ) -> Result<serde_json::Value, String> {
            Ok(serde_json::json!({ "enabled": enabled }))
        }
    }

    #[test]
    fn sysfs_classifies_interfaces_and_never_reports_addresses() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path();
        for (name, wireless, has_device, operstate, carrier, kind_code) in [
            ("lo", false, false, "unknown", "1", "772"),
            ("eth0", false, true, "up", "1", "1"),
            ("wlan0", true, true, "down", "0", "1"),
            ("docker0", false, false, "down", "0", "1"),
        ] {
            let directory = root.join(name);
            std::fs::create_dir_all(&directory).unwrap();
            std::fs::write(directory.join("operstate"), operstate).unwrap();
            std::fs::write(directory.join("carrier"), carrier).unwrap();
            std::fs::write(directory.join("type"), kind_code).unwrap();
            if wireless {
                std::fs::create_dir_all(directory.join("wireless")).unwrap();
            }
            if has_device {
                std::fs::create_dir_all(directory.join("device")).unwrap();
            }
        }

        let source = SysfsInterfaces::with_root(root);
        assert!(source.available());
        let interfaces = source.interfaces().unwrap();
        let by_name = |name: &str| {
            interfaces
                .iter()
                .find(|i| i.name == name)
                .unwrap_or_else(|| panic!("{name} missing"))
                .clone()
        };
        assert_eq!(by_name("lo").kind, "loopback");
        assert_eq!(by_name("eth0").kind, "wired");
        assert_eq!(by_name("wlan0").kind, "wireless");
        assert_eq!(by_name("docker0").kind, "virtual");
        assert_eq!(by_name("eth0").state, "up");
        assert!(by_name("eth0").has_global_address);
        assert!(!by_name("wlan0").has_global_address);
        // Do not infer an externally addressed link from loopback carrier.
        assert!(!by_name("lo").has_global_address);

        // Exclude address and hardware-address fields structurally from redacted status.
        let serialised = serde_json::to_value(&interfaces).unwrap();
        let text = serialised.to_string();
        assert!(!text.contains("address\":\""), "{text}");
        assert!(!text.contains("mac"), "{text}");
    }

    #[test]
    fn a_host_without_sysfs_reports_unavailable_rather_than_guessing() {
        let service = NetworkService::new(
            Arc::new(UnavailableInterfaces),
            Arc::new(RecordingConfigurator),
        );
        let status = service.status().unwrap();
        assert_eq!(status.source, "unavailable");
        assert!(status.interfaces.is_empty());
        assert!(!status.direct_profile);
        assert!(!status.travel_access_point);
    }

    #[test]
    fn configuration_updates_the_reported_profile_state() {
        let service = NetworkService::new(
            Arc::new(UnavailableInterfaces),
            Arc::new(RecordingConfigurator),
        );
        service.configure_direct(true).unwrap();
        service
            .configure_travel_ap(uuid::Uuid::new_v4(), true, None, None)
            .unwrap();
        let status = service.status().unwrap();
        assert!(status.direct_profile);
        assert!(status.travel_access_point);

        service.configure_direct(false).unwrap();
        assert!(!service.status().unwrap().direct_profile);
    }
}
