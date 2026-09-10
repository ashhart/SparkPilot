//! Observe bounded container facts without lifecycle changes or sensitive inspection; report unrepresentable fields as absent, never truncated identities.

/// Container-name prefix for engines this runtime starts (`spark-model-<uuid>`).
pub const MANAGED_ENGINE_PREFIX: &str = "spark-model-";
/// Container-name prefix for project dev containers (`spark-project-<uuid>`).
pub const MANAGED_PROJECT_PREFIX: &str = "spark-project-";

/// Longest container name repeated to a client, from the contract.
const MAX_NAME_LENGTH: usize = 128;
/// Longest image reference repeated to a client, from the contract.
const MAX_IMAGE_LENGTH: usize = 256;
/// Longest container id repeated to a client, from the contract.
const MAX_ID_LENGTH: usize = 64;
/// Published port mappings carried per workload, from the contract.
const MAX_PORTS: usize = 16;
/// Bound host-address text to the longest IPv6 representation.
const MAX_HOST_ADDRESS_LENGTH: usize = 45;
/// Workloads carried in one bounded privileged response, from the contract.
pub const MAX_WORKLOADS: usize = 64;
/// Leave room for the response envelope within the privileged protocol's 64 KiB frame limit.
const MAX_SERIALISED_BYTES: usize = 48 * 1024;

/// Read only this fixed projection, excluding commands, labels and mounts.
const PS_TEMPLATE: &str = "{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Image}}\t{{.Ports}}";

/// Use fixed observation arguments without caller-selected queries.
pub fn ps_argv() -> Vec<String> {
    vec![
        "ps".into(),
        "--all".into(),
        "--no-trunc".into(),
        "--format".into(),
        PS_TEMPLATE.into(),
    ]
}

/// One published host port mapping.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ObservedPort {
    pub host_ip: String,
    pub host_port: u16,
    pub container_port: u16,
    pub protocol: String,
}

/// Carry bounded container evidence; the daemon determines ownership classification.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ObservedContainer {
    pub id: String,
    /// `None` when the runtime reported a name this build will not repeat.
    pub name: Option<String>,
    /// Report recognized lifecycle words directly and unknown for other values.
    pub state: String,
    /// None means the image reference failed output validation.
    pub image: Option<String>,
    pub ports: Vec<ObservedPort>,
}

/// The result of one observation.
#[derive(Debug, Clone, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub struct ObservedWorkloads {
    pub containers: Vec<ObservedContainer>,
    /// The host reported more containers than this response carries.
    pub truncated: bool,
    /// Count unreadable rows so unsupported output cannot masquerade as an idle host.
    #[serde(default)]
    pub unreadable_lines: usize,
}

/// Report unrecognized container lifecycle values as unknown.
const KNOWN_STATES: [&str; 7] = [
    "created",
    "running",
    "paused",
    "restarting",
    "removing",
    "exited",
    "dead",
];

/// Validate projected fields, retaining containers with absent invalid names or images because they still consume resources.
pub fn parse_ps_output(stdout: &str) -> ObservedWorkloads {
    let mut containers = Vec::new();
    let mut truncated = false;
    let mut unreadable_lines = 0_usize;
    let mut budget = MAX_SERIALISED_BYTES;

    for line in stdout.lines() {
        let line = line.trim_end_matches('\r');
        if line.is_empty() {
            continue;
        }
        let mut fields = line.split('\t');
        let (Some(id), Some(names), Some(state), Some(image), ports) = (
            fields.next(),
            fields.next(),
            fields.next(),
            fields.next(),
            fields.next().unwrap_or(""),
        ) else {
            // Count malformed rows so an entirely unreadable projection cannot appear empty.
            unreadable_lines = unreadable_lines.saturating_add(1);
            continue;
        };
        let Some(id) = readable_id(id) else {
            unreadable_lines = unreadable_lines.saturating_add(1);
            continue;
        };

        let container = ObservedContainer {
            id,
            name: readable_name(names),
            state: readable_state(state),
            image: readable_image(image),
            ports: parse_ports(ports),
        };

        if containers.len() >= MAX_WORKLOADS {
            truncated = true;
            break;
        }
        let cost = serialised_cost(&container);
        if cost > budget {
            truncated = true;
            break;
        }
        budget -= cost;
        containers.push(container);
    }

    ObservedWorkloads {
        containers,
        truncated,
        unreadable_lines,
    }
}

/// Measure serialized entry bytes plus separator; treat serialization failures as over budget.
fn serialised_cost(container: &ObservedContainer) -> usize {
    serde_json::to_vec(container).map_or(usize::MAX, |bytes| bytes.len().saturating_add(1))
}

/// Accept only lowercase hexadecimal container IDs.
fn readable_id(raw: &str) -> Option<String> {
    let value = raw.trim();
    if value.is_empty() || value.len() > MAX_ID_LENGTH {
        return None;
    }
    value
        .chars()
        .all(|character| character.is_ascii_hexdigit())
        .then(|| value.to_ascii_lowercase())
}

/// Select the first valid container name; report invalid names as absent.
fn readable_name(raw: &str) -> Option<String> {
    let value = raw.trim().split(',').next()?.trim();
    if value.is_empty() || value.len() > MAX_NAME_LENGTH {
        return None;
    }
    let mut characters = value.chars();
    let first = characters.next()?;
    if !first.is_ascii_alphanumeric() {
        return None;
    }
    characters
        .all(|character| {
            character.is_ascii_alphanumeric()
                || character == '_'
                || character == '.'
                || character == '-'
        })
        .then(|| value.to_owned())
}

fn readable_state(raw: &str) -> String {
    let value = raw.trim().to_ascii_lowercase();
    if KNOWN_STATES.contains(&value.as_str()) {
        value
    } else {
        "unknown".to_owned()
    }
}

/// Accept printable, whitespace-free ASCII image tags or digests.
fn readable_image(raw: &str) -> Option<String> {
    let value = raw.trim();
    if value.is_empty() || value.len() > MAX_IMAGE_LENGTH {
        return None;
    }
    value
        .chars()
        .all(|character| character.is_ascii_graphic())
        .then(|| value.to_owned())
}

/// Parse host-published mappings without expanding port ranges; omit internal ports lacking a host side.
fn parse_ports(raw: &str) -> Vec<ObservedPort> {
    let mut ports = Vec::new();
    for entry in raw.split(',') {
        if ports.len() >= MAX_PORTS {
            break;
        }
        let entry = entry.trim();
        let Some((host, container)) = entry.split_once("->") else {
            continue;
        };
        let (container_span, protocol) = match container.split_once('/') {
            Some((span, protocol)) => (span, protocol.trim().to_ascii_lowercase()),
            None => continue,
        };
        if protocol != "tcp" && protocol != "udp" {
            continue;
        }
        // Split IPv6 mappings at the final colon and omit missing host addresses rather than invent wildcard exposure.
        let Some((host_ip, host_span)) = host.rsplit_once(':') else {
            continue;
        };
        let host_ip = host_ip.trim();
        if host_ip.is_empty()
            || host_ip.len() > MAX_HOST_ADDRESS_LENGTH
            || !host_ip
                .chars()
                .all(|character| character.is_ascii_graphic())
        {
            continue;
        }
        let (Some((host_start, host_end)), Some((container_start, container_end))) =
            (parse_port_span(host_span), parse_port_span(container_span))
        else {
            continue;
        };
        // Reject ranges whose host and container widths differ instead of inventing port pairings.
        if host_end - host_start != container_end - container_start {
            continue;
        }
        for offset in 0..=(host_end - host_start) {
            if ports.len() >= MAX_PORTS {
                break;
            }
            ports.push(ObservedPort {
                host_ip: host_ip.to_owned(),
                host_port: host_start + offset,
                container_port: container_start + offset,
                protocol: protocol.clone(),
            });
        }
    }
    ports
}

/// Preserve inclusive port ranges so published services do not appear to have no exposed ports.
fn parse_port_span(value: &str) -> Option<(u16, u16)> {
    let value = value.trim();
    match value.split_once('-') {
        Some((start, end)) => {
            let start = start.trim().parse::<u16>().ok()?;
            let end = end.trim().parse::<u16>().ok()?;
            (start <= end).then_some((start, end))
        }
        None => {
            let port = value.parse::<u16>().ok()?;
            Some((port, port))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_projection_never_asks_for_a_field_that_can_carry_a_secret() {
        // Exclude commands, environment, labels and mounts because externally managed workloads may store secrets there.
        for forbidden in [".Command", ".Labels", ".Mounts", ".Env"] {
            assert!(
                !PS_TEMPLATE.contains(forbidden),
                "{forbidden} must not appear in the observation projection"
            );
        }
        assert!(ps_argv().iter().all(|argument| argument != "--filter"));
    }

    #[test]
    fn reads_a_managed_engine_and_an_external_service() {
        let observed = parse_ps_output(concat!(
            "9f2c\tspark-model-2b0b0d1e\trunning\tvllm/vllm-openai@sha256:aa\t127.0.0.1:18000->8000/tcp\n",
            "1a3b\tdeepseek-serve\trunning\tsome-registry/sglang:v1\t0.0.0.0:30000->30000/tcp\n",
        ));
        assert!(!observed.truncated);
        assert_eq!(observed.containers.len(), 2);

        let engine = &observed.containers[0];
        assert_eq!(engine.id, "9f2c");
        assert_eq!(engine.name.as_deref(), Some("spark-model-2b0b0d1e"));
        assert_eq!(engine.state, "running");
        assert_eq!(engine.image.as_deref(), Some("vllm/vllm-openai@sha256:aa"));
        assert_eq!(
            engine.ports,
            vec![ObservedPort {
                host_ip: "127.0.0.1".into(),
                host_port: 18000,
                container_port: 8000,
                protocol: "tcp".into(),
            }]
        );

        let external = &observed.containers[1];
        assert_eq!(external.name.as_deref(), Some("deepseek-serve"));
        assert_eq!(external.ports[0].host_port, 30000);
    }

    #[test]
    fn an_unreadable_field_becomes_absent_rather_than_truncated() {
        let long_name = "a".repeat(MAX_NAME_LENGTH + 1);
        let long_image = "b".repeat(MAX_IMAGE_LENGTH + 1);
        let observed = parse_ps_output(&format!(
            "9f2c\t{long_name}\trunning\t{long_image}\t\n\
             1a3b\tokay\trunning\timage with a space\t\n"
        ));
        assert_eq!(observed.containers.len(), 2);
        // Keep the container even when its name cannot be returned.
        assert_eq!(observed.containers[0].name, None);
        assert_eq!(observed.containers[0].image, None);
        assert_eq!(observed.containers[0].state, "running");
        assert_eq!(observed.containers[1].image, None);
    }

    #[test]
    fn an_unrecognised_lifecycle_word_is_unknown_not_guessed() {
        let observed = parse_ps_output("9f2c\tsomething\tsuspended\timage:1\t\n");
        assert_eq!(observed.containers[0].state, "unknown");
        for known in KNOWN_STATES {
            let observed = parse_ps_output(&format!("9f2c\tsomething\t{known}\timage:1\t\n"));
            assert_eq!(observed.containers[0].state, known);
        }
    }

    #[test]
    fn a_mapping_without_a_host_address_is_dropped_not_widened_to_a_wildcard() {
        // A missing address must not become invented wildcard exposure.
        let observed = parse_ps_output("9f2c\tservice\trunning\timage:1\t8000->8000/tcp\n");
        assert!(observed.containers[0].ports.is_empty());
    }

    #[test]
    fn only_published_ports_are_listed() {
        let observed = parse_ps_output(
            "9f2c\tservice\trunning\timage:1\t9000/tcp, 127.0.0.1:18080->8080/tcp, :::8000->8000/tcp, 0.0.0.0:1-3->1-3/tcp\n",
        );
        let ports = &observed.containers[0].ports;
        // Count two single mappings and three ranged ports, excluding unpublished internal ports.
        assert_eq!(ports.len(), 5, "{ports:?}");
        assert_eq!(ports[0].host_ip, "127.0.0.1");
        assert_eq!(ports[0].host_port, 18080);
        // Preserve IPv6 addresses when splitting the final port separator.
        assert_eq!(ports[1].host_ip, "::");
        assert_eq!(ports[1].host_port, 8000);
        assert_eq!(
            ports[2..]
                .iter()
                .map(|port| port.host_port)
                .collect::<Vec<_>>(),
            vec![1, 2, 3]
        );
    }

    #[test]
    fn a_long_host_list_truncates_instead_of_overflowing_the_frame() {
        let mut lines = String::new();
        for index in 0..(MAX_WORKLOADS + 8) {
            lines.push_str(&format!(
                "{index:04x}\tservice-{index}\trunning\timage:1\t\n"
            ));
        }
        let observed = parse_ps_output(&lines);
        assert!(observed.truncated);
        assert!(observed.containers.len() <= MAX_WORKLOADS);
        let serialised = serde_json::to_vec(&observed).expect("serialise");
        assert!(
            serialised.len() < crate::protocol::MAX_RESPONSE_BYTES,
            "inventory must fit one bounded response, was {}",
            serialised.len()
        );
    }

    #[test]
    fn a_wide_host_list_truncates_on_bytes_before_the_frame_limit() {
        // Exercise maximum-width IPv6 mappings so the serialized-byte budget, not just container count, bounds the response.
        let widest_host = "0000:0000:0000:0000:0000:ffff:255.255.255.255";
        assert_eq!(widest_host.len(), 45);
        let ports = (0..32)
            .map(|port| format!("{widest_host}:{}->{}/tcp", 60000 + port, 60000 + port))
            .collect::<Vec<_>>()
            .join(", ");
        let mut lines = String::new();
        for index in 0..MAX_WORKLOADS {
            let name = format!("{}{index:04}", "n".repeat(MAX_NAME_LENGTH - 4));
            let image = "i".repeat(MAX_IMAGE_LENGTH);
            lines.push_str(&format!("{index:04x}\t{name}\trunning\t{image}\t{ports}\n"));
        }
        let observed = parse_ps_output(&lines);
        assert!(observed.truncated);
        assert!(
            observed.containers.len() < MAX_WORKLOADS,
            "the byte budget must bind before the count limit, kept {}",
            observed.containers.len()
        );
        assert!(
            observed
                .containers
                .iter()
                .all(|c| c.ports.len() == MAX_PORTS)
        );
        assert_eq!(observed.containers[0].ports[0].host_ip, widest_host);
        let serialised = serde_json::to_vec(&observed).expect("serialise");
        assert!(
            serialised.len() < crate::protocol::MAX_RESPONSE_BYTES,
            "inventory must fit one bounded response, was {}",
            serialised.len()
        );
    }

    #[test]
    fn a_full_count_of_wide_entries_still_fits_the_frame() {
        // Require maximum-length names and images at the count limit to fit the response frame.
        let mut lines = String::new();
        for index in 0..MAX_WORKLOADS {
            let name = format!("{}{index:04}", "n".repeat(MAX_NAME_LENGTH - 4));
            let image = "i".repeat(MAX_IMAGE_LENGTH);
            lines.push_str(&format!("{index:04x}\t{name}\trunning\t{image}\t\n"));
        }
        let observed = parse_ps_output(&lines);
        assert_eq!(observed.containers.len(), MAX_WORKLOADS);
        let serialised = serde_json::to_vec(&observed).expect("serialise");
        assert!(
            serialised.len() < crate::protocol::MAX_RESPONSE_BYTES,
            "a full inventory must fit one bounded response, was {}",
            serialised.len()
        );
    }

    #[test]
    fn a_malformed_line_is_counted_rather_than_ignored() {
        let observed = parse_ps_output("not-a-projection\n\nzz\tname\trunning\timage:1\t\n");

        assert!(!observed.truncated);

        assert!(observed.containers.is_empty());
        // Unreadable rows must remain distinguishable from an empty host.
        assert_eq!(observed.unreadable_lines, 2);
    }

    #[test]
    fn a_readable_answer_reports_no_unreadable_lines() {
        let observed = parse_ps_output("9f2c\tservice\trunning\timage:1\t\n");
        assert_eq!(observed.unreadable_lines, 0);
        assert_eq!(observed.containers.len(), 1);
    }

    #[test]
    fn a_published_port_range_is_expanded_rather_than_dropped() {
        // Preserve published ranges in the reported service ports.
        let observed =
            parse_ps_output("9f2c\tservice\trunning\timage:1\t0.0.0.0:3000-3003->3000-3003/tcp\n");
        let ports = &observed.containers[0].ports;
        assert_eq!(ports.len(), 4);
        assert_eq!(ports[0].host_port, 3000);
        assert_eq!(ports[0].container_port, 3000);
        assert_eq!(ports[3].host_port, 3003);
        assert_eq!(ports[3].container_port, 3003);
        assert!(ports.iter().all(|port| port.host_ip == "0.0.0.0"));
    }

    #[test]
    fn a_range_that_does_not_line_up_is_dropped_rather_than_paired_by_guesswork() {
        let observed =
            parse_ps_output("9f2c\tservice\trunning\timage:1\t0.0.0.0:3000-3009->4000-4001/tcp\n");
        assert!(observed.containers[0].ports.is_empty());
    }

    #[test]
    fn an_enormous_range_cannot_exceed_the_port_bound() {
        let observed =
            parse_ps_output("9f2c\tservice\trunning\timage:1\t0.0.0.0:1-9000->1-9000/tcp\n");
        assert_eq!(observed.containers[0].ports.len(), MAX_PORTS);
    }
}
