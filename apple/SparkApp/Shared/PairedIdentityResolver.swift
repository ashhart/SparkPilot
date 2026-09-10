import Foundation
import SparkAPI
import SparkCore
import SparkSecurity

/// Authenticate a newly learned address with the existing pairing, never with address metadata.
@MainActor
final class PairedIdentityResolver: AuthenticatedIdentityResolving {
    private let nodeTrustReader: @Sendable (String) -> NodeTrust?
    private let checker: @MainActor (NodeTrust) throws -> any NetworkHandoffIdentityChecking

    convenience init(
        nodeTrustReader: @escaping @Sendable (String) -> NodeTrust?,
        signerProvider: @escaping RetailOnboardingModel.SignerProvider
    ) {
        self.init(nodeTrustReader: nodeTrustReader) { trust in
            guard let nodeID = UUID(uuidString: trust.nodeID) else {
                throw AuthenticatedIdentityError.unbound
            }
            return try SparkAPIClient.pinned(
                to: trust.tlsFingerprint,
                signer: signerProvider(nodeID)
            )
        }
    }

    init(
        nodeTrustReader: @escaping @Sendable (String) -> NodeTrust?,
        checker: @escaping @MainActor (NodeTrust) throws -> any NetworkHandoffIdentityChecking
    ) {
        self.nodeTrustReader = nodeTrustReader
        self.checker = checker
    }

    func resolveIdentity(route: URL, expectedNodeID: SparkNodeID?) async throws
        -> AuthenticatedIdentity
    {
        guard let expectedNodeID,
            let trust = nodeTrustReader(expectedNodeID.rawValue.uuidString.lowercased()),
            UUID(uuidString: trust.nodeID) == expectedNodeID.rawValue
        else { throw AuthenticatedIdentityError.unbound }
        try Task.checkCancellation()
        let client = try checker(trust)
        let identity = try await client.identity(route: route)
        try Task.checkCancellation()
        guard identity.nodeID == expectedNodeID else {
            throw AuthenticatedIdentityError.nodeMismatch(presented: identity.nodeID)
        }
        guard identity.authorityFingerprint.lowercased() == trust.authorityFingerprint.lowercased()
        else { throw AuthenticatedIdentityError.pinRejected }
        return AuthenticatedIdentity(identity: identity, client: client as? SparkAPIClient)
    }
}
