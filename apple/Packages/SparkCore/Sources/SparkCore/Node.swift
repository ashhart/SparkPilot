/// Topology role of a Spark node as advertised in discovery and identity.
public enum SparkNodeRole: String, Codable, Sendable {
    case standalone
    case leader
    case worker
}

/// Treat paired-device roles as server-authoritative capabilities; hiding UI controls does not enforce authorization.
public enum SparkDeviceRole: String, Codable, Sendable {
    case owner
    case administrator
    case developer
    case user
    case observer
}

/// Keep route-kind vocabulary independent of transport scoring and selection.
public enum SparkTransportKind: String, Codable, Sendable {
    case directEthernet
    case localWiFi
    case privateOverlay
}

/// Connection state presented by the node card (§62.1).
public enum SparkConnectionState: String, Codable, Sendable {
    case discovering
    case foundUnpaired
    case connecting
    case connectedWiFi
    case connectedDirect
    case connectedRemote
    case offlineCached
    case identityMismatch
    case updateRequired
}
