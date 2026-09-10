//! Refuse a URL that would reach the Spark itself or the owner's network before any request is made.
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, ToSocketAddrs};

use reqwest::Url;

/// Suffixes that only ever name something inside the house.
const LOCAL_SUFFIXES: &[&str] = &[".local", ".internal", ".localdomain", ".home.arpa", ".lan"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    Invalid,
    Scheme,
    Credentials,
    Port,
    LocalName,
    PrivateAddress,
    Unresolvable,
}

impl Refusal {
    /// One of four documented codes; the private-address classes share one because they share one fix.
    pub fn code(&self) -> &'static str {
        match self {
            Refusal::Invalid | Refusal::Credentials | Refusal::Port => "WEB_FETCH_URL_INVALID",
            Refusal::Scheme => "WEB_FETCH_SCHEME_BLOCKED",
            Refusal::LocalName | Refusal::PrivateAddress => "WEB_FETCH_PRIVATE_ADDRESS",
            Refusal::Unresolvable => "WEB_FETCH_HOST_UNRESOLVABLE",
        }
    }

    /// Shown to the model as the tool result and to the owner in the run's tool list.
    pub fn explanation(&self) -> &'static str {
        match self {
            Refusal::Invalid => "That is not a web address.",
            Refusal::Credentials => "A web address with a username or password in it is not read.",
            Refusal::Port => "Only the ordinary web port 443 is read.",
            Refusal::Scheme => "Only https addresses are read.",
            Refusal::LocalName | Refusal::PrivateAddress => {
                "That address is on this Spark or inside the owner's own network, so it was not read."
            }
            Refusal::Unresolvable => "That address could not be looked up.",
        }
    }
}

/// A name that has no usable answer; the guard treats it the same however it failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResolveFailed;

/// The DNS seam, so every blocked class can be proved without a network.
pub trait HostResolver {
    fn resolve(&self, host: &str) -> Result<Vec<IpAddr>, ResolveFailed>;
}

/// The machine's own resolver.
pub struct SystemResolver;

impl HostResolver for SystemResolver {
    fn resolve(&self, host: &str) -> Result<Vec<IpAddr>, ResolveFailed> {
        (host, 443_u16)
            .to_socket_addrs()
            .map(|addresses| addresses.map(|address| address.ip()).collect())
            .map_err(|_| ResolveFailed)
    }
}

/// A URL that passed every check, with the exact addresses that were checked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Destination {
    pub url: Url,
    pub host: String,
    pub addresses: Vec<IpAddr>,
}

/// Checks one URL at a time; a redirect is re-checked from scratch by the caller.
#[derive(Clone)]
pub struct Guard {
    hostname: String,
}

impl Guard {
    pub fn new(hostname: &str) -> Self {
        Self {
            hostname: hostname.trim_end_matches('.').to_ascii_lowercase(),
        }
    }

    pub fn check(&self, url: &str, resolver: &dyn HostResolver) -> Result<Destination, Refusal> {
        let parsed = Url::parse(url.trim()).map_err(|_| Refusal::Invalid)?;
        // The owner's rule is GET only, TLS only; a cleartext fetch is readable in transit.
        if parsed.scheme() != "https" {
            return Err(Refusal::Scheme);
        }
        if !parsed.username().is_empty() || parsed.password().is_some() {
            return Err(Refusal::Credentials);
        }
        if parsed.port_or_known_default() != Some(443) {
            return Err(Refusal::Port);
        }
        let host = parsed
            .host_str()
            .ok_or(Refusal::Invalid)?
            .trim_end_matches('.')
            .to_ascii_lowercase();
        if host.is_empty() {
            return Err(Refusal::Invalid);
        }
        if let Ok(literal) = host.parse::<IpAddr>() {
            return self.destination(parsed, host, vec![literal]);
        }
        if let Some(stripped) = host.strip_prefix('[').and_then(|v| v.strip_suffix(']'))
            && let Ok(literal) = stripped.parse::<IpAddr>()
        {
            return self.destination(parsed, host, vec![literal]);
        }
        if self.is_local_name(&host) {
            return Err(Refusal::LocalName);
        }
        let addresses = resolver
            .resolve(&host)
            .map_err(|ResolveFailed| Refusal::Unresolvable)?;
        if addresses.is_empty() {
            return Err(Refusal::Unresolvable);
        }
        self.destination(parsed, host, addresses)
    }

    fn destination(
        &self,
        url: Url,
        host: String,
        addresses: Vec<IpAddr>,
    ) -> Result<Destination, Refusal> {
        // Every answer must pass; one private address among public ones is still a way in.
        if addresses.iter().any(|address| is_blocked(*address)) {
            return Err(Refusal::PrivateAddress);
        }
        Ok(Destination {
            url,
            host,
            addresses,
        })
    }

    fn is_local_name(&self, host: &str) -> bool {
        // A fully qualified name may end in a root dot; `spark.local.` names the same machine.
        let host = host.trim_end_matches('.');
        host == "localhost"
            || host == self.hostname
            || host == format!("{}.local", self.hostname)
            || !host.contains('.')
            || LOCAL_SUFFIXES.iter().any(|suffix| host.ends_with(suffix))
    }
}

/// Every address class that is not the public internet.
pub fn is_blocked(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(value) => is_blocked_v4(value),
        IpAddr::V6(value) => is_blocked_v6(value),
    }
}

fn is_blocked_v4(value: Ipv4Addr) -> bool {
    let octets = value.octets();
    value.is_loopback()
        || value.is_private()
        || value.is_link_local()
        || value.is_unspecified()
        || octets[0] == 0
        || value.is_multicast()
        || value.is_broadcast()
        || value.is_documentation()
        // Carrier-grade NAT, where a Tailscale or provider address can live.
        || (octets[0] == 100 && (64..128).contains(&octets[1]))
        // Benchmarking, IETF protocol assignments, 6to4 relay anycast and the reserved top block.
        || (octets[0] == 198 && (octets[1] == 18 || octets[1] == 19))
        || (octets[0] == 192 && octets[1] == 0 && octets[2] == 0)
        || (octets[0] == 192 && octets[1] == 88 && octets[2] == 99)
        || octets[0] >= 240
}

fn is_blocked_v6(value: Ipv6Addr) -> bool {
    let segments = value.segments();
    if value.is_loopback() || value.is_unspecified() || value.is_multicast() {
        return true;
    }
    if segments[..5] == [0, 0, 0, 0, 0] {
        // IPv4-mapped ::ffff:a.b.c.d carries a v4 address; the deprecated ::a.b.c.d form is never followed.
        return match value.to_ipv4() {
            Some(mapped) => segments[5] == 0 || is_blocked_v4(mapped),
            None => true,
        };
    }
    if let Some(embedded) = embedded_v4(segments) {
        return is_blocked_v4(embedded);
    }
    // Link-local fe80::/10, unique-local fc00::/7 and the NAT64 local-use block 64:ff9b:1::/48.
    (segments[0] & 0xffc0) == 0xfe80
        || (segments[0] & 0xfe00) == 0xfc00
        || (segments[0] == 0x0064 && segments[1] == 0xff9b && segments[2] == 1)
        || (segments[0] == 0x2001 && is_reserved_2001(segments[1]))
}

/// Inside 2001::/16: Teredo 2001::/32, benchmarking, ORCHID and documentation are never public hosts.
fn is_reserved_2001(second: u16) -> bool {
    second == 0 || second == 2 || (0x0010..0x0030).contains(&second) || second == 0x0db8
}

/// 6to4 (2002:a.b.c.d::/48) and NAT64 (64:ff9b::a.b.c.d) name their real destination in IPv4.
fn embedded_v4(segments: [u16; 8]) -> Option<Ipv4Addr> {
    if segments[0] == 0x2002 {
        return Some(Ipv4Addr::from(
            (u32::from(segments[1]) << 16) | u32::from(segments[2]),
        ));
    }
    if segments[..6] == [0x0064, 0xff9b, 0, 0, 0, 0] {
        return Some(Ipv4Addr::from(
            (u32::from(segments[6]) << 16) | u32::from(segments[7]),
        ));
    }
    None
}

#[cfg(test)]
#[path = "guard/tests.rs"]
mod tests;
