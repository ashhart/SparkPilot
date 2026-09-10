/// Install state of a model on a node (matches OpenAPI `Model.install_state`).
public enum SparkModelInstallState: String, Codable, Sendable {
    case available
    case downloading
    case verifying
    case installed
    case failed
    case incompatible
    case unverified
}

/// Catalogue-facing state shown to the user (§29.4).
public enum SparkModelUIState: String, Codable, Sendable {
    case available
    case downloading
    case verifying
    case installed
    case ready
    case unloaded
    case updateAvailable
    case incompatible
    case requiresTwoSparks
    case unverified
    case licenceActionRequired
    case failedWithRecovery
}

/// Engine life-cycle state (OpenAPI `InferenceState.state`, §31.4).
public enum SparkInferenceState: String, Codable, Sendable {
    case unloaded
    case loading
    case ready
    case idle
    case draining
    case unloading
    case failed
}
