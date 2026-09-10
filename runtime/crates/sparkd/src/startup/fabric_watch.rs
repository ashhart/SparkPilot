use super::*;

/// Sample often enough that a cable insertion is announced without a replug (adapt.md H).
const FABRIC_SAMPLE_INTERVAL: std::time::Duration = std::time::Duration::from_secs(5);

/// §35.3.1: publish fabric transitions from sysfs and recorded peer proofs, never from privileged access.
pub(super) fn spawn_fabric_watch(state: AppState) {
    let Some(database) = state.database.clone() else {
        return;
    };
    tokio::spawn(async move {
        let sysfs_root = std::path::PathBuf::from(sparkd::fabric::DEFAULT_SYSFS_ROOT);
        let node_id = state.identity.node_id().to_string();
        let mut previous: Option<sparkd::fabric_watch::FabricSample> = None;
        let mut ticker = tokio::time::interval(FABRIC_SAMPLE_INTERVAL);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            ticker.tick().await;
            let now = state.clock.now_rfc3339();
            let peers = {
                let conn = database.lock();
                sparkd::cluster::authenticated_fabric_links_for_node(&conn, &node_id, &now)
                    .map(|links| peers_by_port(&node_id, &links))
                    .unwrap_or_default()
            };
            let root = sysfs_root.clone();
            let sampled =
                tokio::task::spawn_blocking(move || sparkd::fabric_watch::sample(&root, &peers))
                    .await;
            let Ok(Ok(current)) = sampled else {
                // A node without ConnectX hardware reports nothing; that is not a change to announce.
                previous = None;
                continue;
            };
            if let Some(previous) = &previous {
                for change in sparkd::fabric_watch::transitions(previous, &current) {
                    let conn = database.lock();
                    state.events.emit(
                        Some(&conn),
                        &node_id,
                        None,
                        change.event_type,
                        change.severity,
                        change.payload,
                    );
                }
            }
            previous = Some(current);
        }
    });
}

/// Reduce reciprocal links to this node's own port-to-peer map.
fn peers_by_port(
    node_id: &str,
    links: &[sparkd::cluster::AuthenticatedFabricLink],
) -> std::collections::BTreeMap<String, String> {
    let mut peers = std::collections::BTreeMap::new();
    for link in links {
        if link.member_a_node_id == node_id {
            peers.insert(link.member_a_port_id.clone(), link.member_b_node_id.clone());
        } else if link.member_b_node_id == node_id {
            peers.insert(link.member_b_port_id.clone(), link.member_a_node_id.clone());
        }
    }
    peers
}
