// Reference memory signals and the local-address probe used only while sparkd starts.

/// Provide deterministic reference memory signals only when procfs is unavailable.
pub(crate) struct ReferenceSignals;

impl spark_telemetry::MemorySource for ReferenceSignals {
    fn signals(&self) -> spark_telemetry::MemorySignals {
        spark_telemetry::MemorySignals::calm(137_438_953_472).with_available(28_743_895_347)
    }
}

/// Read the address the default route would source from, via a UDP socket that sends nothing; `None` when there is no route.
pub(crate) fn primary_local_ip() -> Option<std::net::IpAddr> {
    let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    socket.local_addr().ok().map(|addr| addr.ip())
}
