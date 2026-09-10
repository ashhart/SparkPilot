//! Advertise untrusted, secret-free mDNS hints; obtain full node identity through the secure identity endpoint.

use std::collections::HashMap;

use uuid::Uuid;

/// Discovery record keys with stable string values.
pub const TXT_KEY_API: &str = "api";
pub const TXT_KEY_NODE: &str = "node";
pub const TXT_KEY_CLUSTER: &str = "cluster";
pub const TXT_KEY_PAIRING: &str = "pairing";
pub const TXT_KEY_ROLE: &str = "role";
pub const TXT_KEY_TLS: &str = "tls";
pub const TXT_KEY_RUNTIME: &str = "runtime";

pub const SERVICE_TYPE: &str = "_spark-runtime._tcp";
pub const SERVICE_TYPE_FQN: &str = "_spark-runtime._tcp.local.";
pub const DOMAIN: &str = "local.";

/// Standalone nodes advertise cluster=none.
pub const CLUSTER_NONE: &str = "none";

/// First 8 hex characters of the node UUID (discovery hint only).
pub fn short_node_id(node_id: Uuid) -> String {
    node_id.simple().to_string()[..8].to_owned()
}

/// First eight TLS fingerprint hex characters for discovery only, never trust verification.
pub fn short_fingerprint(fingerprint: &str) -> String {
    fingerprint.chars().take(8).collect()
}

/// Normalize instance names to the DNS label alphabet and reserve space for the node-ID suffix.
pub fn instance_label(node_name: &str, short_node_id: &str) -> String {
    let mut cleaned = String::new();
    let mut last_was_separator = false;
    for character in node_name.chars() {
        let usable = character.is_ascii_alphanumeric();
        if usable {
            cleaned.push(character);
            last_was_separator = false;
        } else if !last_was_separator && !cleaned.is_empty() {
            cleaned.push('-');
            last_was_separator = true;
        }
    }
    while cleaned.ends_with('-') {
        cleaned.pop();
    }
    if cleaned.is_empty() {
        cleaned.push_str("spark");
    }
    // 63 bytes is the DNS label limit; leave room for "-<8 hex>".
    let room = 63usize.saturating_sub(short_node_id.len() + 1);
    if cleaned.len() > room {
        cleaned.truncate(room);
        while cleaned.ends_with('-') {
            cleaned.pop();
        }
    }
    format!("{cleaned}-{short_node_id}")
}

/// Build the discovery TXT records.
pub fn txt_properties(
    node_id: Uuid,
    tls_fingerprint: Option<&str>,
    runtime_version: &str,
    role: &str,
    pairing: &str,
    cluster: &str,
) -> HashMap<String, String> {
    let mut props = HashMap::new();
    props.insert(TXT_KEY_API.to_owned(), "1".to_owned());
    props.insert(TXT_KEY_NODE.to_owned(), short_node_id(node_id));
    props.insert(TXT_KEY_CLUSTER.to_owned(), cluster.to_owned());
    props.insert(TXT_KEY_PAIRING.to_owned(), pairing.to_owned());
    props.insert(TXT_KEY_ROLE.to_owned(), role.to_owned());
    if let Some(fingerprint) = tls_fingerprint {
        props.insert(TXT_KEY_TLS.to_owned(), short_fingerprint(fingerprint));
    }
    props.insert(TXT_KEY_RUNTIME.to_owned(), runtime_version.to_owned());
    props
}

/// Register synchronously and keep the returned daemon alive to retain the advertisement.
pub fn advertise(
    node_id: Uuid,
    instance_name: &str,
    tls_fingerprint: Option<&str>,
    runtime_version: &str,
    port: u16,
) -> Result<mdns_sd::ServiceDaemon, mdns_sd::Error> {
    let service = service_info(
        node_id,
        instance_name,
        tls_fingerprint,
        runtime_version,
        port,
    )?;
    let daemon = mdns_sd::ServiceDaemon::new()?;
    daemon.register(service)?;
    Ok(daemon)
}

fn service_info(
    node_id: Uuid,
    instance_name: &str,
    tls_fingerprint: Option<&str>,
    runtime_version: &str,
    port: u16,
) -> Result<mdns_sd::ServiceInfo, mdns_sd::Error> {
    let props = txt_properties(
        node_id,
        tls_fingerprint,
        runtime_version,
        "standalone",
        "closed",
        CLUSTER_NONE,
    );
    let host_name = format!("{instance_name}.{DOMAIN}");
    // Track interface changes so Wi-Fi can acquire its address after sparkd starts.
    Ok(mdns_sd::ServiceInfo::new(
        SERVICE_TYPE_FQN,
        instance_name,
        host_name.as_str(),
        "",
        port,
        props,
    )?
    .enable_addr_auto())
}

#[cfg(test)]
mod instance_label_tests {
    use super::*;

    /// Normalize free-form node names into resolvable DNS labels within 63 bytes.
    #[test]
    fn a_free_form_node_name_becomes_a_usable_mdns_label() {
        assert_eq!(
            instance_label("example-spark", "7a836150"),
            "example-spark-7a836150"
        );
        // Preserve letter case while replacing dots, spaces and punctuation.
        assert_eq!(
            instance_label("Alex's Spark.local", "7a836150"),
            "Alex-s-Spark-local-7a836150"
        );
        // A name of nothing usable still advertises something resolvable.
        assert_eq!(instance_label("...", "7a836150"), "spark-7a836150");
        assert_eq!(instance_label("", "7a836150"), "spark-7a836150");
        // Control characters never reach the wire.
        let label = instance_label("bad\u{7}name", "7a836150");
        assert!(!label.chars().any(char::is_control), "{label}");
        // The whole label fits inside the 63-byte DNS limit.
        let long = instance_label(&"n".repeat(200), "7a836150");
        assert!(long.len() <= 63, "{} bytes: {long}", long.len());
        assert!(long.ends_with("-7a836150"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_boot_without_a_lan_route_does_not_pin_discovery_to_localhost() {
        let service = service_info(
            Uuid::nil(),
            "spark-startup-qa",
            Some("2479ebf5"),
            "0.1.12",
            7443,
        )
        .unwrap();
        assert!(
            service.is_addr_auto(),
            "discovery must follow interfaces that acquire an address after startup"
        );
        assert!(
            service.get_addresses().iter().all(|ip| !ip.is_loopback()),
            "localhost must never be frozen into the Spark's advertised route"
        );
    }

    #[test]
    fn txt_contract_matches_discovery_schema() {
        let id = Uuid::parse_str("7a836150-16e1-46b5-8ac0-32b2a5f2f820").unwrap();
        let props = txt_properties(
            id,
            Some("a9f2c76194a56b80372c67d874306e4f1234567890abcdef"),
            "0.1.0",
            "standalone",
            "closed",
            CLUSTER_NONE,
        );

        assert_eq!(props.get(TXT_KEY_API).map(String::as_str), Some("1"));
        assert_eq!(
            props.get(TXT_KEY_NODE).map(String::as_str),
            Some("7a836150")
        );
        assert_eq!(props.get(TXT_KEY_CLUSTER).map(String::as_str), Some("none"));
        assert_eq!(
            props.get(TXT_KEY_PAIRING).map(String::as_str),
            Some("closed")
        );
        assert_eq!(
            props.get(TXT_KEY_ROLE).map(String::as_str),
            Some("standalone")
        );
        assert_eq!(props.get(TXT_KEY_TLS).map(String::as_str), Some("a9f2c761"));
        assert_eq!(
            props.get(TXT_KEY_RUNTIME).map(String::as_str),
            Some("0.1.0")
        );
        // Keep TXT fingerprints as short discovery hints rather than authentication evidence.
        assert!(
            props.values().all(|v| !v.contains("1234567890abcdef")),
            "TXT values must not leak the full fingerprint"
        );
        assert!(!props.contains_key("key") && !props.contains_key("seed"));
    }

    #[test]
    fn insecure_development_advertisement_has_no_tls_pin() {
        let id = Uuid::parse_str("7a836150-16e1-46b5-8ac0-32b2a5f2f820").unwrap();
        let props = txt_properties(id, None, "0.1.0", "standalone", "closed", CLUSTER_NONE);
        assert!(!props.contains_key(TXT_KEY_TLS));
    }
}
