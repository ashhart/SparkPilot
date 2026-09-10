//! Read-only detection for private overlay routes configured outside SparkPilot.

use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrivateOverlayRoute {
    pub provider: String,
    /// What the app connects to: the MagicDNS name when known, otherwise the overlay address.
    pub hostname: String,
    /// The 100.64/10 address sparkd reached itself on, kept as evidence beside the name.
    pub address: Option<String>,
}

/// Tailscale hands out addresses only from the CGNAT range 100.64.0.0/10.
pub fn is_tailscale_ipv4(address: Ipv4Addr) -> bool {
    let octets = address.octets();
    octets[0] == 100 && (64..=127).contains(&octets[1])
}

pub trait PrivateOverlayProbe: Send + Sync {
    fn route(&self) -> Result<Option<PrivateOverlayRoute>, String>;
}

/// Detect existing Tailscale routes without installation, login or provider reconfiguration.
pub struct TailscaleOverlayProbe {
    sparkd_port: u16,
    connect_timeout: Duration,
}

impl TailscaleOverlayProbe {
    pub fn new(sparkd_port: u16) -> Self {
        Self {
            sparkd_port,
            connect_timeout: Duration::from_secs(2),
        }
    }

    fn is_tailscale_ipv4(address: Ipv4Addr) -> bool {
        is_tailscale_ipv4(address)
    }
}

impl PrivateOverlayProbe for TailscaleOverlayProbe {
    fn route(&self) -> Result<Option<PrivateOverlayRoute>, String> {
        let candidate = if_addrs::get_if_addrs()
            .map_err(|error| error.to_string())?
            .into_iter()
            .find_map(|interface| {
                if interface.name != "tailscale0" {
                    return None;
                }
                match interface.ip() {
                    IpAddr::V4(address) if Self::is_tailscale_ipv4(address) => {
                        Some(IpAddr::V4(address))
                    }
                    _ => None,
                }
            });
        let Some(address) = candidate else {
            return Ok(None);
        };
        let socket = SocketAddr::new(address, self.sparkd_port);
        if TcpStream::connect_timeout(&socket, self.connect_timeout).is_err() {
            return Ok(None);
        }
        Ok(Some(PrivateOverlayRoute {
            provider: "tailscale".into(),
            hostname: address.to_string(),
            address: Some(address.to_string()),
        }))
    }
}

#[derive(Debug, Default)]
pub struct UnavailablePrivateOverlay;

impl PrivateOverlayProbe for UnavailablePrivateOverlay {
    fn route(&self) -> Result<Option<PrivateOverlayRoute>, String> {
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::TailscaleOverlayProbe;

    #[test]
    fn only_the_tailscale_cgnat_range_is_accepted() {
        assert!(TailscaleOverlayProbe::is_tailscale_ipv4(
            "100.64.0.1".parse().unwrap()
        ));
        assert!(TailscaleOverlayProbe::is_tailscale_ipv4(
            "100.127.255.254".parse().unwrap()
        ));
        assert!(!TailscaleOverlayProbe::is_tailscale_ipv4(
            "100.128.0.1".parse().unwrap()
        ));
        assert!(!TailscaleOverlayProbe::is_tailscale_ipv4(
            "192.168.1.10".parse().unwrap()
        ));
    }
}
