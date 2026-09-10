use super::*;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WifiNetwork {
    pub ssid: String,
    pub security: String,
    pub signal_percent: u8,
    pub connected: bool,
    pub saved: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct TravelAccessPointStatus {
    pub enabled: bool,
    pub ssid: Option<String>,
    pub security: String,
    pub auto_revert_seconds: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BluetoothDeviceStatus {
    pub address: String,
    pub name: String,
    pub paired: bool,
    pub connected: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct BluetoothStatus {
    pub available: bool,
    pub powered: bool,
    pub discovering: bool,
    pub nearby_devices: Vec<BluetoothDeviceStatus>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PowerProfileMode {
    pub mode_id: u8,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct PowerProfileStatus {
    pub available: bool,
    pub current_mode_id: Option<u8>,
    pub current_name: Option<String>,
    pub modes: Vec<PowerProfileMode>,
    pub reboot_required: bool,
    pub temperature_celsius: Option<f64>,
    pub power_draw_watts: Option<f64>,
    pub power_limit_watts: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SoftwareUpdateStatus {
    pub checked_at: String,
    pub system_packages_available: Option<u64>,
    pub firmware_updates_available: Option<u64>,
    pub runtime_release_id: Option<String>,
    pub reboot_required: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SystemTimeStatus {
    pub timezone: String,
    pub ntp_enabled: bool,
    pub synchronized: bool,
}

impl Default for SystemTimeStatus {
    fn default() -> Self {
        Self {
            timezone: "Etc/UTC".into(),
            ntp_enabled: false,
            synchronized: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HostSettingsStatus {
    pub direct_ethernet_enabled: bool,
    pub travel_access_point: TravelAccessPointStatus,
    pub bluetooth: BluetoothStatus,
    pub power_profile: PowerProfileStatus,
    pub software_updates: SoftwareUpdateStatus,
    pub time: SystemTimeStatus,
}

#[async_trait]
pub trait ApplianceStatusProvider: Send + Sync {
    async fn host_settings(&self, observed_at: &str) -> HostSettingsStatus;
    async fn wifi_networks(&self) -> Vec<WifiNetwork>;
    async fn container_storage(&self) -> (u64, u64);
}

#[derive(Debug, Default)]
pub struct SystemApplianceStatusProvider;

pub fn default_appliance_status_provider() -> Arc<dyn ApplianceStatusProvider> {
    Arc::new(SystemApplianceStatusProvider)
}

#[async_trait]
impl ApplianceStatusProvider for SystemApplianceStatusProvider {
    async fn host_settings(&self, observed_at: &str) -> HostSettingsStatus {
        let network = network_feature_status().await;
        let (bluetooth, power_profile, software_updates, time) = tokio::join!(
            bluetooth_status(),
            power_profile_status(),
            software_update_status(observed_at),
            system_time_status(),
        );
        HostSettingsStatus {
            direct_ethernet_enabled: network.0,
            travel_access_point: network.1,
            bluetooth,
            power_profile,
            software_updates,
            time,
        }
    }

    async fn wifi_networks(&self) -> Vec<WifiNetwork> {
        wifi_scan().await
    }

    async fn container_storage(&self) -> (u64, u64) {
        docker_storage().await
    }
}
