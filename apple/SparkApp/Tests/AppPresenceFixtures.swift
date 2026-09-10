import CryptoKit
import Foundation
import Network
import SparkAPI
import SparkAppComposition
import SparkDiscovery
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing

enum AppTestPresenceOutcome: Sendable {
    case allow
    case decline
}

actor AppTestPresenceAuthorizer: UserPresenceAuthorizing {
    private let outcome: AppTestPresenceOutcome
    private var authorizationCount = 0

    init(outcome: AppTestPresenceOutcome = .allow) {
        self.outcome = outcome
    }

    func keyInfo() async throws -> UserPresenceKeyInfo {
        AppShellTestAppTestPresenceSession().keyInfo
    }

    func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning {
        authorizationCount += 1
        switch outcome {
        case .allow:
            return AppShellTestAppTestPresenceSession()
        case .decline:
            throw UserPresenceAuthorizationError.declined
        }
    }

    func recordedAuthorizationCount() -> Int { authorizationCount }
}
