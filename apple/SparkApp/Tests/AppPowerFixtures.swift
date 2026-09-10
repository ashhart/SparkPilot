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

enum AppShellTestFakePowerFailure: Sendable {
    case network
    case rejected
}

actor AppShellTestFakePower: SparkPowerControlling {
    private var failures: [AppShellTestFakePowerFailure]
    private var calls: [(SparkPowerAction, UUID)] = []

    init(failures: [AppShellTestFakePowerFailure] = []) {
        self.failures = failures
    }

    func rebootSpark(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        try submit(.reboot, key: idempotencyKey)
    }

    func shutdownSpark(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        try submit(.shutdown, key: idempotencyKey)
    }

    private func submit(_ action: SparkPowerAction, key: UUID) throws -> SparkAPI.Operation {
        calls.append((action, key))
        if !failures.isEmpty {
            switch failures.removeFirst() {
            case .network:
                throw URLError(.networkConnectionLost)
            case .rejected:
                throw APIError(
                    .local(message: "The owner grant is required."),
                    statusCode: 403,
                    code: "ROLE_FORBIDDEN"
                )
            }
        }
        return try appShellTestDecode(
            "{\"id\":\"63e82da2-7fb7-4b4b-9584-4a528000ac94\","
                + "\"kind\":\"power.\(action.rawValue)\",\"state\":\"queued\","
                + "\"cancellable\":false}"
        )
    }

    func recordedCalls() -> [(SparkPowerAction, UUID)] { calls }
}
