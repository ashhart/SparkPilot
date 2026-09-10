import Foundation
import Observation
import CoreImage.CIFilterBuiltins
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDesignSystem
import SparkDiscovery
import SparkSecurity
import SwiftUI
@MainActor
@Observable
final class SparkSettingsOperationCoordinator {
    var activeMutation: String?
    var errorMessage: String?
    var successMessage: String?
    var lastOperation: SparkAPI.Operation?
    // A successful metadata check cannot establish whether an earlier install finished.
    var softwareUpdateRecoveryMessage: String?
    private var pendingSoftwareUpdate: SparkAPI.Operation?
    var hasPendingSoftwareUpdate: Bool { pendingSoftwareUpdate != nil }

    enum SoftwareUpdateAction { case install, check }

    func reconcileSoftwareUpdate() async {
        guard let pending = pendingSoftwareUpdate,
            let current = try? await runtime.operation(route: route, id: pending.id)
        else { return }
        lastOperation = current
        if current.state == .succeeded {
            softwareUpdateRecoveryMessage = nil
            pendingSoftwareUpdate = nil
        } else if current.state == .failed || current.state == .cancelled {
            pendingSoftwareUpdate = nil
        }
    }
    var route: URL
    private let runtime: any SparkSettingsManaging
    private let userPresenceAuthorizer: any UserPresenceAuthorizing
    private let presenceEnrollmentProvider: (any DeviceManagementProviding)?
    private var presenceEnrollmentKey: UUID?
    var pendingNetworkChange: () -> PendingSparkNetworkChange? = { nil }
    var clearOptimisticState: () -> Void = {}
    var refresh: () async -> Void = {}

    init(route: URL, runtime: any SparkSettingsManaging, authorizer: any UserPresenceAuthorizing) {
        self.route = route
        self.runtime = runtime
        self.userPresenceAuthorizer = authorizer
        self.presenceEnrollmentProvider = runtime as? any DeviceManagementProviding
    }

    func perform(
        label: String,
        reason: String,
        waitsThroughReconnect: Bool = false,
        softwareUpdateAction: SoftwareUpdateAction? = nil,
        submit: @escaping (any UserPresenceProofSigning) async throws -> SparkAPI.Operation
    ) async {
        guard activeMutation == nil, pendingNetworkChange() == nil else {
            // Report an in-flight change so optimistic controls cannot imply that a second mutation was accepted.
            clearOptimisticState()
            errorMessage =
                pendingNetworkChange() != nil
                ? String(localized: "Keep or undo the pending network change first.")
                : String(localized: "Another change is still being applied. Wait for it to finish.")
            return
        }
        activeMutation = label
        errorMessage = nil
        successMessage = nil
        defer { activeMutation = nil }
        var submittedOperation: SparkAPI.Operation?
        do {
            var operation = try await submitAuthorized(
                reason: reason,
                enrollmentRoute: route,
                submit: submit
            )
            submittedOperation = operation
            lastOperation = operation
            operation = try await waitForCompletion(
                operation,
                waitsThroughReconnect: waitsThroughReconnect
            )
            lastOperation = operation
            guard operation.state == .succeeded else {
                throw APIError(
                    .local(message: String(localized: "The Spark did not apply this setting.")),
                    code: operation.errorCode
                )
            }
            if softwareUpdateAction == .install {
                softwareUpdateRecoveryMessage = nil
                pendingSoftwareUpdate = nil
            }
            await refresh()
            if errorMessage == nil, softwareUpdateRecoveryMessage == nil {
                successMessage = String(localized: .actionComplete(label))
            }
        } catch {
            clearOptimisticState()
            if softwareUpdateAction == .install, let submittedOperation {
                let latest = lastOperation ?? submittedOperation
                if latest.state != .failed && latest.state != .cancelled {
                    pendingSoftwareUpdate = latest
                }
                softwareUpdateRecoveryMessage = String(
                    localized:
                        "SparkPilot could not confirm that installation finished. Some updates may have installed. Review the latest status before trying again."
                )
                await refresh()
                return
            }
            if softwareUpdateAction == .check {
                errorMessage = String(
                    localized:
                        "The update check did not finish. Refresh to see the latest status, then try checking again."
                )
                return
            }
            if error is UserPresenceAuthorizationError {
                errorMessage =
                    String(
                        localized:
                            "Nothing changed because this Apple device could not confirm you are present."
                    )
            } else if let api = error as? APIError, api.code == "NETWORK_AUTHENTICATION_FAILED" {
                errorMessage = String(
                    localized: "That Wi-Fi password is wrong. Check it and try again."
                )
            } else if let api = error as? APIError, api.code == "OPERATION_LEASE_EXPIRED" {
                // The runtime stopped renewing the operation, usually because it restarted to apply an update; show the real state.
                errorMessage = SparkSettingsFailurePresentation.operationLeaseExpiredMessage(label)
                await refresh()
            } else if let api = error as? APIError, api.code == "SETTING_STILL_APPLYING" {
                // Keep an unresolved operation marked running to avoid inviting duplicate submission.
                errorMessage = String(
                    localized:
                        "The Spark is still applying that setting. Refresh in a moment before trying again."
                )
            } else if let api = error as? APIError, let code = api.code {
                // Map the runtime's specific refusal code to its recovery explanation.
                let cause =
                    api.statusCode.map {
                        String(localized: .reasonWithHTTPStatus(reason: code, status: $0))
                    } ?? code
                errorMessage = String(localized: .nothingChangedReported(cause))
            } else {
                errorMessage = String(
                    localized: "Nothing changed. The Spark could not apply that setting."
                )
            }
        }
    }

    func waitForCompletion(
        _ submitted: SparkAPI.Operation,
        polling operationRoute: URL? = nil,
        waitsThroughReconnect: Bool = false,
        onProgress: (@MainActor (SparkAPI.Operation) -> Void)? = nil
    ) async throws
        -> SparkAPI.Operation
    {
        var operation = submitted
        let attempts = waitsThroughReconnect ? 600 : 120
        for _ in 0..<attempts {
            switch operation.state {
            case .succeeded, .failed, .cancelled:
                return operation
            default:
                try await Task.sleep(
                    for: waitsThroughReconnect ? .seconds(1) : .milliseconds(500)
                )
                do {
                    operation = try await runtime.operation(
                        route: operationRoute ?? route,
                        id: operation.id
                    )
                    lastOperation = operation
                    onProgress?(operation)
                } catch  where waitsThroughReconnect {
                    continue
                }
            }
        }
        throw APIError(
            .local(message: String(localized: "The setting is still being applied.")),
            code: "SETTING_STILL_APPLYING"
        )
    }

    func submitAuthorized(
        reason: String,
        enrollmentRoute: URL,
        submit: @escaping (any UserPresenceProofSigning) async throws -> SparkAPI.Operation
    ) async throws -> SparkAPI.Operation {
        let presence = try await userPresenceAuthorizer.authorize(localizedReason: reason)
        do {
            return try await submit(presence)
        } catch {
            guard (error as? APIError)?.code == "USER_PRESENCE_NOT_REGISTERED" else {
                throw error
            }
            try await enrollPresenceKey(route: enrollmentRoute)
            let retry = try await userPresenceAuthorizer.authorize(localizedReason: reason)
            return try await submit(retry)
        }
    }

    private func enrollPresenceKey(route enrollmentRoute: URL) async throws {
        guard let presenceEnrollmentProvider else {
            throw APIError(
                .local(message: String(localized: "Presence-key enrollment is unavailable.")),
                code: "USER_PRESENCE_ENROLLMENT_UNAVAILABLE"
            )
        }
        let presence = try await userPresenceAuthorizer.authorize(
            localizedReason: String(
                localized: "Confirm upgrading protected actions for this Apple device."
            )
        )
        let key = presenceEnrollmentKey ?? UUID()
        presenceEnrollmentKey = key
        do {
            _ = try await presenceEnrollmentProvider.enrollPresenceKey(
                route: enrollmentRoute,
                idempotencyKey: key,
                userPresence: presence
            )
            presenceEnrollmentKey = nil
        } catch {
            if Self.isDefinitiveRejection(error) { presenceEnrollmentKey = nil }
            throw error
        }
    }

    private static func isDefinitiveRejection(_ error: any Error) -> Bool {
        guard let status = (error as? APIError)?.statusCode else { return false }
        return (400...499).contains(status)
    }
}
