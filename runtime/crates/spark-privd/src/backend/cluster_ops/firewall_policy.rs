use super::*;

pub(super) fn cluster_firewall_table(cluster_id: uuid::Uuid, transaction_id: uuid::Uuid) -> String {
    let digest = Sha256::digest(format!("{cluster_id}\0{transaction_id}"));
    format!("spc_{}", hex::encode(&digest[..8]))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn cluster_firewall_owner_marker(
    transaction_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    peer_node_id: uuid::Uuid,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
    interface: &str,
) -> String {
    format!(
        "sparkpilot-cluster-firewall-v1:transaction={transaction_id}:cluster={cluster_id}:local-node={local_node_id}:peer-node={peer_node_id}:local-address={local_address}:peer-address={peer_address}:interface={interface}"
    )
}

pub(super) fn firewall_install_script(
    table: &str,
    marker: &str,
    interface: &str,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
) -> String {
    format!(
        "add table inet {table} {{ comment \"{marker}\"; }}\n\
         add chain inet {table} input {{ type filter hook input priority -50; policy accept; }}\n\
         add rule inet {table} input iifname \"{interface}\" ip saddr {peer_address} ip daddr {local_address} tcp dport {{ {CLUSTER_TCP_PORTS} }} accept comment \"{marker}:allow-member-tcp\"\n\
         add rule inet {table} input iifname \"{interface}\" ip saddr {peer_address} ip daddr {local_address} udp dport {{ {CLUSTER_UDP_PORTS} }} accept comment \"{marker}:allow-member-udp\"\n\
         add rule inet {table} input iifname \"{interface}\" tcp dport {{ {CLUSTER_TCP_PORTS} }} drop comment \"{marker}:deny-fabric-tcp-from-lan\"\n\
         add rule inet {table} input iifname \"{interface}\" udp dport {{ {CLUSTER_UDP_PORTS} }} drop comment \"{marker}:deny-fabric-udp-from-lan\"\n\
         add rule inet {table} input iifname \"{interface}\" drop comment \"{marker}:deny-other-fabric\""
    )
}

pub(super) fn cluster_firewall_evidence(
    backend: &DockerBackend,
    table: &str,
) -> Result<Option<serde_json::Value>, BackendError> {
    let output = backend.run_appliance(
        NFT_BIN,
        vec![
            "--json".into(),
            "--numeric".into(),
            "list".into(),
            "table".into(),
            "inet".into(),
            table.into(),
        ],
        None,
    )?;
    if !output.success() {
        let detail = output.stderr_text().to_ascii_lowercase();
        if detail.contains("no such file") || detail.contains("not found") {
            return Ok(None);
        }
        return Err(BackendError::Failure(
            "nftables could not inspect the cluster firewall".into(),
        ));
    }
    serde_json::from_slice(&output.stdout)
        .map(Some)
        .map_err(|_| {
            BackendError::Failure("nftables returned malformed cluster firewall evidence".into())
        })
}

pub(super) fn firewall_policy_entries(
    evidence: &serde_json::Value,
) -> Option<&[serde_json::Value]> {
    let root = evidence.as_object()?;
    if root.len() != 1 {
        return None;
    }
    let entries = root.get("nftables")?.as_array()?;
    let mut start = 0;
    if let Some(first) = entries.first().and_then(serde_json::Value::as_object)
        && first.len() == 1
        && first
            .get("metainfo")
            .is_some_and(serde_json::Value::is_object)
    {
        start = 1;
    }
    Some(&entries[start..])
}

pub(super) fn object_matches_exact_fields(
    object: &serde_json::Map<String, serde_json::Value>,
    expected: &[(&str, serde_json::Value)],
) -> bool {
    let has_handle = object
        .get("handle")
        .is_some_and(|value| value.as_u64().is_some());
    if object.len() != expected.len() + usize::from(has_handle) {
        return false;
    }
    expected
        .iter()
        .all(|(key, value)| object.get(*key) == Some(value))
}

pub(super) fn wrapper_object<'a>(
    value: &'a serde_json::Value,
    kind: &str,
) -> Option<&'a serde_json::Map<String, serde_json::Value>> {
    let wrapper = value.as_object()?;
    if wrapper.len() != 1 {
        return None;
    }
    wrapper.get(kind)?.as_object()
}

pub(super) fn exact_table_marker<'a>(
    evidence: &'a serde_json::Value,
    table: &str,
) -> Option<&'a str> {
    let entries = firewall_policy_entries(evidence)?;
    let object = wrapper_object(entries.first()?, "table")?;
    let marker = object.get("comment")?.as_str()?;
    object_matches_exact_fields(
        object,
        &[
            ("family", serde_json::json!("inet")),
            ("name", serde_json::json!(table)),
            ("comment", serde_json::json!(marker)),
        ],
    )
    .then_some(marker)
}

pub(super) fn exact_port_ranges(value: &serde_json::Value) -> Option<Vec<(u16, u16)>> {
    fn one(value: &serde_json::Value) -> Option<(u16, u16)> {
        if let Some(port) = value.as_u64().and_then(|port| u16::try_from(port).ok()) {
            return Some((port, port));
        }
        let object = value.as_object()?;
        if object.len() != 1 {
            return None;
        }
        let range = object.get("range")?.as_array()?;
        if range.len() != 2 {
            return None;
        }
        let start = range[0]
            .as_u64()
            .and_then(|port| u16::try_from(port).ok())?;
        let end = range[1]
            .as_u64()
            .and_then(|port| u16::try_from(port).ok())?;
        (start <= end).then_some((start, end))
    }

    let mut ranges = if let Some(object) = value.as_object() {
        if object.len() == 1 && object.contains_key("set") {
            object
                .get("set")?
                .as_array()?
                .iter()
                .map(one)
                .collect::<Option<Vec<_>>>()?
        } else {
            vec![one(value)?]
        }
    } else {
        vec![one(value)?]
    };
    ranges.sort_unstable();
    if ranges.windows(2).any(|pair| pair[0].1 >= pair[1].0) {
        return None;
    }
    Some(ranges)
}

pub(super) fn exact_match_expression(
    value: &serde_json::Value,
    operator: &str,
    left: serde_json::Value,
    right: serde_json::Value,
) -> bool {
    let Some(expression) = wrapper_object(value, "match") else {
        return false;
    };
    object_matches_exact_fields(
        expression,
        &[
            ("op", serde_json::json!(operator)),
            ("left", left),
            ("right", right),
        ],
    )
}

pub(super) fn exact_port_match_expression(
    value: &serde_json::Value,
    protocol: &str,
    expected: &[(u16, u16)],
) -> bool {
    let Some(expression) = wrapper_object(value, "match") else {
        return false;
    };
    object_matches_exact_fields(
        expression,
        &[
            ("op", serde_json::json!("==")),
            (
                "left",
                serde_json::json!({ "payload": { "protocol": protocol, "field": "dport" } }),
            ),
            (
                "right",
                expression.get("right").cloned().unwrap_or_default(),
            ),
        ],
    ) && expression
        .get("right")
        .and_then(exact_port_ranges)
        .as_deref()
        == Some(expected)
}

pub(super) fn exact_verdict(value: &serde_json::Value, verdict: &str) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    object.len() == 1 && object.get(verdict) == Some(&serde_json::Value::Null)
}

pub(super) fn exact_rule<'a>(
    value: &'a serde_json::Value,
    table: &str,
    comment: &str,
    expected_expressions: usize,
) -> Option<&'a [serde_json::Value]> {
    let object = wrapper_object(value, "rule")?;
    let expressions = object.get("expr")?.as_array()?;
    if expressions.len() != expected_expressions
        || !object_matches_exact_fields(
            object,
            &[
                ("family", serde_json::json!("inet")),
                ("table", serde_json::json!(table)),
                ("chain", serde_json::json!("input")),
                ("expr", serde_json::json!(expressions)),
                ("comment", serde_json::json!(comment)),
            ],
        )
    {
        return None;
    }
    Some(expressions)
}

pub(super) fn exact_cluster_firewall_policy(
    evidence: &serde_json::Value,
    table: &str,
    marker: &str,
    interface: &str,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
) -> bool {
    let Some(entries) = firewall_policy_entries(evidence) else {
        return false;
    };
    if entries.len() != 7 || exact_table_marker(evidence, table) != Some(marker) {
        return false;
    }
    let Some(chain) = wrapper_object(&entries[1], "chain") else {
        return false;
    };
    if !object_matches_exact_fields(
        chain,
        &[
            ("family", serde_json::json!("inet")),
            ("table", serde_json::json!(table)),
            ("name", serde_json::json!("input")),
            ("type", serde_json::json!("filter")),
            ("hook", serde_json::json!("input")),
            ("prio", serde_json::json!(-50)),
            ("policy", serde_json::json!("accept")),
        ],
    ) {
        return false;
    }

    let tcp_ports = [
        (6_379, 6_379),
        (8_265, 8_265),
        (10_001, 10_003),
        (11_000, 11_063),
        (18_100, 18_199),
        (19_443, 19_443),
        (24_000, 65_535),
    ];
    let udp_ports = [(24_000, 65_535)];
    let iif = serde_json::json!({ "meta": { "key": "iifname" } });
    let saddr = serde_json::json!({ "payload": { "protocol": "ip", "field": "saddr" } });
    let daddr = serde_json::json!({ "payload": { "protocol": "ip", "field": "daddr" } });

    let Some(member_tcp) = exact_rule(&entries[2], table, &format!("{marker}:allow-member-tcp"), 5)
    else {
        return false;
    };
    if !exact_match_expression(
        &member_tcp[0],
        "==",
        iif.clone(),
        serde_json::json!(interface),
    ) || !exact_match_expression(
        &member_tcp[1],
        "==",
        saddr.clone(),
        serde_json::json!(peer_address.to_string()),
    ) || !exact_match_expression(
        &member_tcp[2],
        "==",
        daddr.clone(),
        serde_json::json!(local_address.to_string()),
    ) || !exact_port_match_expression(&member_tcp[3], "tcp", &tcp_ports)
        || !exact_verdict(&member_tcp[4], "accept")
    {
        return false;
    }

    let Some(member_udp) = exact_rule(&entries[3], table, &format!("{marker}:allow-member-udp"), 5)
    else {
        return false;
    };
    if !exact_match_expression(
        &member_udp[0],
        "==",
        iif.clone(),
        serde_json::json!(interface),
    ) || !exact_match_expression(
        &member_udp[1],
        "==",
        saddr,
        serde_json::json!(peer_address.to_string()),
    ) || !exact_match_expression(
        &member_udp[2],
        "==",
        daddr,
        serde_json::json!(local_address.to_string()),
    ) || !exact_port_match_expression(&member_udp[3], "udp", &udp_ports)
        || !exact_verdict(&member_udp[4], "accept")
    {
        return false;
    }

    for (entry, protocol, ports, comment) in [
        (
            &entries[4],
            "tcp",
            tcp_ports.as_slice(),
            format!("{marker}:deny-fabric-tcp-from-lan"),
        ),
        (
            &entries[5],
            "udp",
            udp_ports.as_slice(),
            format!("{marker}:deny-fabric-udp-from-lan"),
        ),
    ] {
        let Some(expressions) = exact_rule(entry, table, &comment, 3) else {
            return false;
        };
        if !exact_match_expression(
            &expressions[0],
            "==",
            iif.clone(),
            serde_json::json!(interface),
        ) || !exact_port_match_expression(&expressions[1], protocol, ports)
            || !exact_verdict(&expressions[2], "drop")
        {
            return false;
        }
    }

    let Some(deny_other) = exact_rule(
        &entries[6],
        table,
        &format!("{marker}:deny-other-fabric"),
        2,
    ) else {
        return false;
    };
    exact_match_expression(&deny_other[0], "==", iif, serde_json::json!(interface))
        && exact_verdict(&deny_other[1], "drop")
}
