//! Owner-facing Tailscale setup state and the privileged provisioner behind one-tap remote access.

use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream};
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::remote_overlay::{PrivateOverlayProbe, PrivateOverlayRoute, is_tailscale_ipv4};

mod preferences;
pub use preferences::{OverlayPreferenceChange, OverlayPreferences};

/// Only a sign-in link on this exact origin is ever shown to the owner.
const LOGIN_LINK_PREFIX: &str = "https://login.tailscale.com/a/";

/// A status read is a socket round trip; a prepare may install a package and waits for sign-in.
const STATUS_DEADLINE: Duration = Duration::from_secs(15);

/// A rollback is two short commands; it must not hang an already-failing enable.
const ROLLBACK_DEADLINE: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OverlaySetupState {
    NotInstalled,
    Stopped,
    LoginRequired,
    ApprovalRequired,
    Connecting,
    Ready,
    Unavailable,
}

impl OverlaySetupState {
    pub fn api_name(self) -> &'static str {
        match self {
            Self::NotInstalled => "not_installed",
            Self::Stopped => "stopped",
            Self::LoginRequired => "login_required",
            Self::ApprovalRequired => "approval_required",
            Self::Connecting => "connecting",
            Self::Ready => "ready",
            Self::Unavailable => "unavailable",
        }
    }
}

/// The `RemoteOverlaySetup` document: what the helper knows about the Spark's Tailscale client.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OverlaySetup {
    pub provider: String,
    pub state: OverlaySetupState,
    #[serde(default)]
    pub authorization_url: Option<String>,
    #[serde(default)]
    pub hostname: Option<String>,
    #[serde(default)]
    pub address: Option<String>,
    #[serde(default)]
    pub tailnet: Option<String>,
    #[serde(default)]
    pub installable: Option<bool>,
    #[serde(default)]
    pub detail: Option<String>,
    /// The helper started a unit that was not already running; a rollback may stop it again.
    #[serde(default)]
    pub created_service: Option<bool>,
    /// The helper ran `tailscale up`; a rollback may sign out again.
    #[serde(default)]
    pub attempted_login: Option<bool>,
}

impl OverlaySetup {
    pub fn tailscale() -> Self {
        Self {
            provider: "tailscale".into(),
            state: OverlaySetupState::Unavailable,
            authorization_url: None,
            hostname: None,
            address: None,
            tailnet: None,
            installable: None,
            detail: None,
            created_service: None,
            attempted_login: None,
        }
    }

    pub fn unavailable(detail: impl Into<String>) -> Self {
        Self {
            detail: Some(detail.into()),
            ..Self::tailscale()
        }
    }

    /// Whether `prepare` can carry this state to `ready` without the owner touching the Spark.
    pub fn can_prepare(&self) -> bool {
        match self.state {
            OverlaySetupState::Ready
            | OverlaySetupState::LoginRequired
            | OverlaySetupState::ApprovalRequired
            | OverlaySetupState::Connecting
            | OverlaySetupState::Stopped => true,
            OverlaySetupState::NotInstalled => self.installable == Some(true),
            OverlaySetupState::Unavailable => false,
        }
    }

    pub fn is_ready(&self) -> bool {
        self.state == OverlaySetupState::Ready
    }
}

/// What a failed enable has to undo, taken from what the helper reported it did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OverlayRollback {
    pub logout: bool,
    pub disable_service: bool,
}

impl OverlayRollback {
    /// Only what this prepare created is ever undone; an existing tailnet membership is left alone.
    pub fn after(setup: &OverlaySetup) -> Self {
        Self {
            logout: setup.attempted_login.unwrap_or(false),
            disable_service: setup.created_service.unwrap_or(false),
        }
    }

    pub fn is_empty(self) -> bool {
        !self.logout && !self.disable_service
    }
}

/// What a rollback managed, and what it had to leave behind.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct OverlayRollbackReport {
    #[serde(default)]
    pub logged_out: bool,
    #[serde(default)]
    pub service_disabled: bool,
    /// Named states that are still in place, for example `signed_in` or `tailscaled_enabled`.
    #[serde(default)]
    pub remaining: Vec<String>,
}

impl OverlayRollbackReport {
    /// A sentence the owner can act on when something could not be undone.
    pub fn remaining_summary(&self) -> String {
        self.remaining
            .iter()
            .map(|state| match state.as_str() {
                "signed_in" => "this Spark is still signed in to your tailnet",
                "tailscaled_enabled" => "the Tailscale service is still enabled and running",
                _ => "part of the Tailscale setup is still in place",
            })
            .collect::<Vec<_>>()
            .join("; ")
    }
}

/// Drive the Spark's own Tailscale client through the privileged helper.
pub trait PrivateOverlayProvisioner: Send + Sync {
    fn preferences(&self) -> Result<OverlayPreferences, String> {
        Err("Tailscale preference management is unavailable in this runtime".into())
    }
    fn configure(
        &self,
        _request_id: uuid::Uuid,
        _change: OverlayPreferenceChange,
    ) -> Result<OverlayPreferences, String> {
        Err("Tailscale preference management is unavailable in this runtime".into())
    }
    /// Install, start and request sign-in as needed; returns the state reached, with the owner's link when one is needed.
    fn prepare(&self) -> Result<OverlaySetup, String>;
    /// Read the current state without changing anything.
    fn status(&self) -> Result<OverlaySetup, String>;
    /// Undo exactly what a failed prepare started.
    fn roll_back(&self, undo: OverlayRollback) -> Result<OverlayRollbackReport, String>;
}

/// Composition without a privileged helper (the mock backend): setup is honestly unavailable.
#[derive(Debug, Default)]
pub struct UnavailableOverlayProvisioner;

const NO_HELPER: &str = "no privileged helper is available to set up Tailscale on this Spark";

impl PrivateOverlayProvisioner for UnavailableOverlayProvisioner {
    fn prepare(&self) -> Result<OverlaySetup, String> {
        Err(NO_HELPER.into())
    }

    fn status(&self) -> Result<OverlaySetup, String> {
        Ok(OverlaySetup::unavailable(NO_HELPER))
    }

    fn roll_back(&self, _undo: OverlayRollback) -> Result<OverlayRollbackReport, String> {
        Err(NO_HELPER.into())
    }
}

pub fn trusted_login_link(value: &str) -> bool {
    value.strip_prefix(LOGIN_LINK_PREFIX).is_some_and(|token| {
        !token.is_empty()
            && token.len() <= 256
            && token.bytes().all(|byte| byte.is_ascii_alphanumeric())
    })
}

fn plausible_hostname(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 253
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.'))
        && !value.starts_with('.')
        && !value.ends_with('.')
}

/// Re-check the helper's answer at the daemon boundary so a compromised helper cannot steer the owner or the app.
pub fn validate_helper_setup(setup: OverlaySetup) -> Result<OverlaySetup, String> {
    if setup.provider != "tailscale" {
        return Err("privileged helper named an unknown overlay provider".into());
    }
    if let Some(url) = &setup.authorization_url
        && !trusted_login_link(url)
    {
        return Err("privileged helper returned an untrusted sign-in link".into());
    }
    if let Some(address) = &setup.address
        && !address.parse::<Ipv4Addr>().is_ok_and(is_tailscale_ipv4)
    {
        return Err("privileged helper returned an address outside Tailscale's range".into());
    }
    if let Some(hostname) = &setup.hostname
        && !plausible_hostname(hostname)
    {
        return Err("privileged helper returned an unusable hostname".into());
    }
    Ok(setup)
}

/// The production provisioner: two typed helper operations, no caller-supplied arguments.
pub struct PrivdOverlayProvisioner {
    client: crate::privd::PrivilegedClient,
}

impl PrivdOverlayProvisioner {
    pub fn new(client: crate::privd::PrivilegedClient) -> Self {
        Self { client }
    }

    fn call(
        &self,
        operation: spark_privd::protocol::PrivilegedOperation,
        deadline: Option<Duration>,
    ) -> Result<OverlaySetup, String> {
        let response = match deadline {
            Some(deadline) => self.client.call_bounded(operation, deadline),
            None => self.client.call(operation),
        }
        .map_err(|error| error.to_string())?;
        if !response.accepted {
            return Err(format!("{}: {}", response.code, response.message));
        }
        let setup: OverlaySetup =
            serde_json::from_value(response.details).map_err(|error| error.to_string())?;
        validate_helper_setup(setup)
    }
}

impl PrivateOverlayProvisioner for PrivdOverlayProvisioner {
    fn preferences(&self) -> Result<OverlayPreferences, String> {
        self.preferences_call(
            spark_privd::protocol::PrivilegedOperation::TailscalePreferences {
                request_id: uuid::Uuid::new_v4(),
            },
            Duration::from_secs(25),
        )
    }

    fn configure(
        &self,
        request_id: uuid::Uuid,
        change: OverlayPreferenceChange,
    ) -> Result<OverlayPreferences, String> {
        if !change.is_valid() {
            return Err("change exactly one Tailscale preference".into());
        }
        self.preferences_call(
            spark_privd::protocol::PrivilegedOperation::ConfigureTailscale {
                request_id,
                enabled: change.enabled,
                accept_dns: change.accept_dns,
            },
            Duration::from_secs(95),
        )
    }

    fn prepare(&self) -> Result<OverlaySetup, String> {
        self.call(
            spark_privd::protocol::PrivilegedOperation::PrepareTailscale {
                request_id: uuid::Uuid::new_v4(),
            },
            None,
        )
    }

    fn status(&self) -> Result<OverlaySetup, String> {
        self.call(
            spark_privd::protocol::PrivilegedOperation::TailscaleStatus {
                request_id: uuid::Uuid::new_v4(),
            },
            Some(STATUS_DEADLINE),
        )
    }

    fn roll_back(&self, undo: OverlayRollback) -> Result<OverlayRollbackReport, String> {
        let response = self
            .client
            .call_bounded(
                spark_privd::protocol::PrivilegedOperation::RollBackTailscale {
                    request_id: uuid::Uuid::new_v4(),
                    logout: undo.logout,
                    disable_service: undo.disable_service,
                },
                ROLLBACK_DEADLINE,
            )
            .map_err(|error| error.to_string())?;
        if !response.accepted {
            return Err(format!("{}: {}", response.code, response.message));
        }
        serde_json::from_value(response.details).map_err(|error| error.to_string())
    }
}

/// Turn the helper's ready state into a route only after sparkd reaches itself over the overlay address.
pub struct ProvisionedOverlayProbe {
    provisioner: Arc<dyn PrivateOverlayProvisioner>,
    sparkd_port: u16,
    connect_timeout: Duration,
    self_probe: bool,
}

impl ProvisionedOverlayProbe {
    pub fn new(provisioner: Arc<dyn PrivateOverlayProvisioner>, sparkd_port: u16) -> Self {
        Self {
            provisioner,
            sparkd_port,
            connect_timeout: Duration::from_secs(2),
            self_probe: true,
        }
    }

    /// Tests script the helper and have no listener on the overlay address.
    pub fn without_self_probe(provisioner: Arc<dyn PrivateOverlayProvisioner>) -> Self {
        Self {
            provisioner,
            sparkd_port: 0,
            connect_timeout: Duration::from_millis(1),
            self_probe: false,
        }
    }
}

impl PrivateOverlayProbe for ProvisionedOverlayProbe {
    fn route(&self) -> Result<Option<PrivateOverlayRoute>, String> {
        let setup = self.provisioner.status()?;
        if !setup.is_ready() {
            return Ok(None);
        }
        let Some(address) = setup.address.clone() else {
            return Ok(None);
        };
        if self.self_probe {
            let ip: Ipv4Addr = address
                .parse()
                .map_err(|_| "overlay address is not IPv4".to_owned())?;
            let socket = SocketAddr::new(IpAddr::V4(ip), self.sparkd_port);
            if TcpStream::connect_timeout(&socket, self.connect_timeout).is_err() {
                return Ok(None);
            }
        }
        Ok(Some(PrivateOverlayRoute {
            provider: setup.provider,
            hostname: setup.hostname.unwrap_or_else(|| address.clone()),
            address: Some(address),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ready(hostname: &str, address: &str) -> OverlaySetup {
        OverlaySetup {
            state: OverlaySetupState::Ready,
            hostname: Some(hostname.into()),
            address: Some(address.into()),
            ..OverlaySetup::tailscale()
        }
    }

    #[test]
    fn helper_answers_are_revalidated_at_the_daemon_boundary() {
        assert!(validate_helper_setup(ready("spark.tail1234.ts.net", "100.96.4.2")).is_ok());
        assert!(validate_helper_setup(ready("spark.tail1234.ts.net", "192.168.1.9")).is_err());
        assert!(validate_helper_setup(ready("spark evil", "100.96.4.2")).is_err());
        let mut foreign = ready("spark.tail1234.ts.net", "100.96.4.2");
        foreign.provider = "wireguard".into();
        assert!(validate_helper_setup(foreign).is_err());
        let mut link = OverlaySetup::tailscale();
        link.state = OverlaySetupState::LoginRequired;
        link.authorization_url = Some("https://login.tailscale.com.evil.example/a/1".into());
        assert!(validate_helper_setup(link.clone()).is_err());
        link.authorization_url = Some("https://login.tailscale.com/a/0123456789abcdef".into());
        assert!(validate_helper_setup(link).is_ok());
    }

    #[test]
    fn only_states_the_helper_can_carry_to_ready_are_preparable() {
        let mut setup = OverlaySetup::tailscale();
        for state in [
            OverlaySetupState::Ready,
            OverlaySetupState::LoginRequired,
            OverlaySetupState::ApprovalRequired,
            OverlaySetupState::Connecting,
            OverlaySetupState::Stopped,
        ] {
            setup.state = state;
            assert!(setup.can_prepare(), "{state:?}");
        }
        setup.state = OverlaySetupState::Unavailable;
        assert!(!setup.can_prepare());
        setup.state = OverlaySetupState::NotInstalled;
        assert!(!setup.can_prepare());
        setup.installable = Some(true);
        assert!(setup.can_prepare());
    }

    #[test]
    fn a_ready_helper_state_becomes_a_route_named_by_magicdns() {
        struct Fixed(OverlaySetup);
        impl PrivateOverlayProvisioner for Fixed {
            fn prepare(&self) -> Result<OverlaySetup, String> {
                Ok(self.0.clone())
            }
            fn status(&self) -> Result<OverlaySetup, String> {
                Ok(self.0.clone())
            }
            fn roll_back(&self, _undo: OverlayRollback) -> Result<OverlayRollbackReport, String> {
                Ok(OverlayRollbackReport::default())
            }
        }
        let probe = ProvisionedOverlayProbe::without_self_probe(Arc::new(Fixed(ready(
            "spark-example.tail1234.ts.net",
            "100.96.4.2",
        ))));
        let route = probe.route().unwrap().unwrap();
        assert_eq!(route.hostname, "spark-example.tail1234.ts.net");
        assert_eq!(route.address.as_deref(), Some("100.96.4.2"));

        let signed_out = ProvisionedOverlayProbe::without_self_probe(Arc::new(Fixed(
            OverlaySetup::unavailable("signed out"),
        )));
        assert_eq!(signed_out.route().unwrap(), None);
    }
}
