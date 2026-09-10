import Foundation
import Network
import Observation
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkDesignSystem
import SparkLibrary
import SparkIntents
import SparkSecurity
import SparkTransport

enum AdditionalDevicePairingError: Error, Equatable {
    case grantForAnotherSpark
}

actor BatchPresenceSessionProvider {
    private let authorizer: any UserPresenceAuthorizing
    private var cached: (session: any UserPresenceProofSigning, createdAt: Date)?

    init(authorizer: any UserPresenceAuthorizing) {
        self.authorizer = authorizer
    }

    func session(forceRefresh: Bool = false) async throws -> any UserPresenceProofSigning {
        if !forceRefresh, let cached,
            Date().timeIntervalSince(cached.createdAt) < 45
        {
            return cached.session
        }
        let session = try await authorizer.authorize(
            localizedReason: String(
                localized: "Confirm adding this Apple device to the selected Sparks."
            )
        )
        cached = (session, Date())
        return session
    }
}

enum RetailSignerError: Error { case invalidNodeID }
