use super::*;

fn port(link: &str, speed: Option<u64>, peer: Option<&str>) -> FabricPortSample {
    FabricPortSample {
        physical_link: link.to_owned(),
        negotiated_speed_mbps: speed,
        authenticated_peer_node_id: peer.map(str::to_owned),
    }
}

fn names(changes: &[FabricTransition]) -> Vec<&'static str> {
    changes.iter().map(|change| change.event_type).collect()
}

#[test]
fn inserting_a_cable_announces_carrier_then_speed_then_ready() {
    let down: FabricSample = [("left".to_owned(), port("down", None, None))].into();
    let carrier: FabricSample = [("left".to_owned(), port("carrier", None, None))].into();
    let slow: FabricSample = [(
        "left".to_owned(),
        port("speed_mismatch", Some(100_000), None),
    )]
    .into();
    let fast: FabricSample = [(
        "left".to_owned(),
        port("negotiated_200_gbe", Some(200_000), None),
    )]
    .into();

    assert_eq!(
        names(&transitions(&down, &carrier)),
        ["fabric.carrier_detected"]
    );
    let negotiating = transitions(&carrier, &slow);
    assert_eq!(names(&negotiating), ["fabric.speed_changed"]);
    assert_eq!(negotiating[0].severity, "warning");
    assert_eq!(negotiating[0].payload["negotiated_speed_mbps"], 100_000);

    let ready = transitions(&slow, &fast);
    assert_eq!(names(&ready), ["fabric.speed_changed", "fabric.ready"]);
    assert_eq!(ready[1].payload["port_id"], "left");
}

#[test]
fn a_cable_already_in_before_boot_is_still_announced_once() {
    let empty = FabricSample::new();
    let present: FabricSample = [(
        "right".to_owned(),
        port("negotiated_200_gbe", Some(200_000), None),
    )]
    .into();
    // adapt.md H: a cable present at start must not need a replug to be seen.
    assert_eq!(
        names(&transitions(&empty, &present)),
        ["fabric.carrier_detected"]
    );
    // Steady state is silent.
    assert!(transitions(&present, &present).is_empty());
}

#[test]
fn pulling_the_cable_degrades_the_port_and_a_vanished_port_degrades_too() {
    let up: FabricSample = [(
        "left".to_owned(),
        port("negotiated_200_gbe", Some(200_000), Some("peer-node")),
    )]
    .into();
    let down: FabricSample = [("left".to_owned(), port("down", None, Some("peer-node")))].into();
    let degraded = transitions(&up, &down);
    assert_eq!(names(&degraded), ["fabric.degraded"]);
    assert_eq!(degraded[0].severity, "warning");

    let gone = FabricSample::new();
    assert_eq!(names(&transitions(&up, &gone)), ["fabric.degraded"]);
}

#[test]
fn a_peer_is_announced_only_when_it_proves_itself_and_only_once() {
    let candidate: FabricSample = [(
        "left".to_owned(),
        port("negotiated_200_gbe", Some(200_000), None),
    )]
    .into();
    let proven: FabricSample = [(
        "left".to_owned(),
        port("negotiated_200_gbe", Some(200_000), Some("peer-node")),
    )]
    .into();
    // Carrier alone never announces a peer.
    assert!(
        !names(&transitions(&FabricSample::new(), &candidate))
            .contains(&"fabric.peer_authenticated")
    );
    let announced = transitions(&candidate, &proven);
    assert_eq!(names(&announced), ["fabric.peer_authenticated"]);
    assert_eq!(announced[0].payload["peer_node_id"], "peer-node");
    assert!(transitions(&proven, &proven).is_empty());

    // A different peer on the same port is a new announcement.
    let replaced: FabricSample = [(
        "left".to_owned(),
        port("negotiated_200_gbe", Some(200_000), Some("other-node")),
    )]
    .into();
    assert_eq!(
        names(&transitions(&proven, &replaced)),
        ["fabric.peer_authenticated"]
    );
}

#[test]
fn sampling_reads_sysfs_and_binds_recorded_peer_proofs() {
    let root = tempfile::tempdir().unwrap();
    let device = root.path().join("enp1s0f0np0");
    std::fs::create_dir_all(device.join("device")).unwrap();
    std::fs::write(device.join("device/vendor"), "0x15b3\n").unwrap();
    std::fs::write(device.join("carrier"), "1\n").unwrap();
    std::fs::write(device.join("speed"), "200000\n").unwrap();

    let observed = sample(root.path(), &BTreeMap::new()).unwrap();
    let (port_id, state) = observed.iter().next().unwrap();
    assert_eq!(state.physical_link, "negotiated_200_gbe");
    assert_eq!(state.negotiated_speed_mbps, Some(200_000));
    assert!(state.authenticated_peer_node_id.is_none());

    let peers: BTreeMap<String, String> = [(port_id.clone(), "peer-node".to_owned())].into();
    let bound = sample(root.path(), &peers).unwrap();
    assert_eq!(
        bound[port_id].authenticated_peer_node_id.as_deref(),
        Some("peer-node")
    );
}
