//! Turn ConnectX port observations into the §35.3.1 fabric event family without privileged access.

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::{Value, json};

/// One port's observable state: the physical-link rung plus whether its peer has proven itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FabricPortSample {
    pub physical_link: String,
    pub negotiated_speed_mbps: Option<u64>,
    pub authenticated_peer_node_id: Option<String>,
}

/// The whole fabric as one comparable snapshot, keyed by physical port.
pub type FabricSample = BTreeMap<String, FabricPortSample>;

/// A change worth telling the owner about, ready for the event bus.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FabricTransition {
    pub event_type: &'static str,
    pub severity: &'static str,
    pub payload: Value,
}

/// Read sysfs and the recorded peer proofs into one sample; neither call spawns a process.
pub fn sample(
    sysfs_root: &Path,
    authenticated_peers: &BTreeMap<String, String>,
) -> Result<FabricSample, String> {
    let links = crate::fabric::observe_port_links(sysfs_root)?;
    Ok(links
        .into_iter()
        .map(|(port_id, (carrier, speed))| {
            let sample = FabricPortSample {
                physical_link: crate::fabric::physical_link_state(carrier, speed).to_owned(),
                negotiated_speed_mbps: speed,
                authenticated_peer_node_id: authenticated_peers.get(&port_id).cloned(),
            };
            (port_id, sample)
        })
        .collect())
}

/// Compare two samples and name every §35.3.1 transition between them.
pub fn transitions(previous: &FabricSample, current: &FabricSample) -> Vec<FabricTransition> {
    let mut changes = Vec::new();
    for (port_id, now) in current {
        let before = previous.get(port_id);
        let was_down = before.is_none_or(|state| state.physical_link == "down");
        let is_down = now.physical_link == "down";
        if was_down && !is_down {
            changes.push(carrier_event(port_id, now));
        }
        if !was_down && is_down {
            changes.push(FabricTransition {
                event_type: "fabric.degraded",
                severity: "warning",
                payload: json!({"port_id": port_id, "physical_link": now.physical_link}),
            });
        }
        if let Some(before) = before
            && !was_down
            && !is_down
            && before.negotiated_speed_mbps != now.negotiated_speed_mbps
        {
            changes.push(FabricTransition {
                event_type: "fabric.speed_changed",
                severity: if now.physical_link == "speed_mismatch" {
                    "warning"
                } else {
                    "info"
                },
                payload: json!({
                    "port_id": port_id,
                    "physical_link": now.physical_link,
                    "negotiated_speed_mbps": now.negotiated_speed_mbps,
                }),
            });
        }
        if before.is_some_and(|state| state.physical_link != "negotiated_200_gbe")
            && now.physical_link == "negotiated_200_gbe"
        {
            changes.push(FabricTransition {
                event_type: "fabric.ready",
                severity: "info",
                payload: json!({
                    "port_id": port_id,
                    "negotiated_speed_mbps": now.negotiated_speed_mbps,
                }),
            });
        }
        if let Some(peer) = &now.authenticated_peer_node_id
            && before.is_none_or(|state| state.authenticated_peer_node_id.as_ref() != Some(peer))
        {
            changes.push(FabricTransition {
                event_type: "fabric.peer_authenticated",
                severity: "notice",
                payload: json!({"port_id": port_id, "peer_node_id": peer}),
            });
        }
    }
    for (port_id, before) in previous {
        if !current.contains_key(port_id) && before.physical_link != "down" {
            changes.push(FabricTransition {
                event_type: "fabric.degraded",
                severity: "warning",
                payload: json!({"port_id": port_id, "physical_link": "down"}),
            });
        }
    }
    changes
}

/// A first observation that already has carrier still announces it, so a cable in before boot is seen.
fn carrier_event(port_id: &str, now: &FabricPortSample) -> FabricTransition {
    FabricTransition {
        event_type: "fabric.carrier_detected",
        severity: "info",
        payload: json!({
            "port_id": port_id,
            "physical_link": now.physical_link,
            "negotiated_speed_mbps": now.negotiated_speed_mbps,
        }),
    }
}

#[cfg(test)]
#[path = "fabric_watch/tests.rs"]
mod tests;
