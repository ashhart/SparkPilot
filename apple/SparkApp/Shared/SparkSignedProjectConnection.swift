import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity

/// A pinned, signed route to one paired Spark's project API, built the same way everywhere.
struct SparkSignedProjectConnection {
    let route: URL
    let expectedNodeID: SparkNodeID
    let expectedAuthorityFingerprint: String
    let api: SparkAPIClient

    /// Refuse anything that is not a healthy, first-party, paired entry with stored trust.
    @MainActor static func make(library: SparkLibrary, targetID: String) throws -> Self {
        guard let entry = library.entry(id: targetID),
            entry.issue == nil,
            entry.externalClusterRegistration == nil,
            let nodeID = entry.coordinatorNodeID,
            let route = entry.connectRoute?.baseURL,
            let trust = StoredNodeTrust.reader(nodeID.rawValue.uuidString.lowercased())
        else {
            throw APIError(
                .local(message: String(localized: "No authenticated Spark route is available."))
            )
        }
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: nodeID.rawValue)
        return Self(
            route: route,
            expectedNodeID: nodeID,
            expectedAuthorityFingerprint: trust.authorityFingerprint,
            api: try SparkAPIClient.pinned(to: trust.tlsFingerprint, signer: signer)
        )
    }
}
