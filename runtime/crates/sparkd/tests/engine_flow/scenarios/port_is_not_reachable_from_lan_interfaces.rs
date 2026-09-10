#[tokio::test]
async fn port_is_not_reachable_from_lan_interfaces() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();

    let operation_id: uuid::Uuid = load_model(&client, addr, &key, &device_id, None).await["id"]
        .as_str()
        .and_then(|s| uuid::Uuid::parse_str(s).ok())
        .expect("load operation id");
    wait_terminal(&h.state, operation_id, Duration::from_secs(10)).await;

    let engine_port = h.engine.internal_port().expect("engine port");
    // Refuse engine connections through every non-loopback host interface.
    let addrs = if_addrs::get_if_addrs()
        .expect("interfaces")
        .into_iter()
        .map(|i| i.ip())
        .filter(|ip| !ip.is_loopback())
        .collect::<Vec<_>>();
    if addrs.is_empty() {
        return; // headless CI host with only loopback
    }
    for ip in addrs {
        let connected = std::net::TcpStream::connect_timeout(
            &SocketAddr::new(ip, engine_port),
            Duration::from_millis(500),
        );
        assert!(
            connected.is_err(),
            "engine port {engine_port} reachable from non-loopback {ip}"
        );
    }
}
