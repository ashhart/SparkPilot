import Foundation
import Observation
import SparkAPI
import SparkDesignSystem
import SparkSecurity

/// Observe a bounded durable operation without owning the screen's mutable state.
struct RemoteAccessOperationPoller: Sendable {
    let runtime: any RemoteAccessReading
    let route: URL
    let maximumPolls: Int
    let delay: @Sendable (Duration) async throws -> Void

    func wait(
        for accepted: SparkAPI.Operation,
        observe: @MainActor @Sendable (SparkAPI.Operation) -> Void
    ) async throws -> SparkAPI.Operation {
        var operation = accepted
        var pollsRemaining = maximumPolls
        while !Self.isTerminal(operation.state) {
            guard pollsRemaining > 0 else {
                throw APIError(
                    .local(
                        message: String(localized: "The remote-access operation is still running.")
                    ),
                    code: "REMOTE_DISABLE_STATUS_TIMEOUT"
                )
            }
            pollsRemaining -= 1
            try await delay(.seconds(1))
            operation = try await runtime.operation(route: route, id: operation.id)
            await observe(operation)
        }
        return operation
    }

    private static func isTerminal(_ state: SparkAPI.Operation.OperationState) -> Bool {
        switch state {
        case .succeeded, .failed, .cancelled: true
        default: false
        }
    }
}
