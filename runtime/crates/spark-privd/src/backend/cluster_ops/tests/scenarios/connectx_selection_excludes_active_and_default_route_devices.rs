#[test]
fn connectx_selection_excludes_active_and_default_route_devices() {
    let mut excluded =
        parse_active_ethernet_devices(b"enp1s0:802-3-ethernet\nwlan0:802-11-wireless\n")
            .unwrap();
    excluded.extend(
        parse_default_route_devices(b"default via 192.168.1.1 dev enp2s0 proto dhcp\n")
            .unwrap(),
    );
    assert_eq!(
        choose_connectx_candidate(
            vec!["enp2s0".into(), "cx7b".into(), "enp1s0".into()],
            &excluded,
        )
        .unwrap(),
        "cx7b"
    );
}
