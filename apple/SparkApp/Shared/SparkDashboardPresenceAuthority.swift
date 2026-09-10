import Foundation
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import IOKit.ps
#endif
import Observation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SparkSecurity
import SwiftUI
import UniformTypeIdentifiers
@MainActor
final class SparkDashboardPresenceAuthority {
    private let route: URL
    private let userPresenceAuthorizer: any UserPresenceAuthorizing
    private let presenceEnrollmentProvider: (any DeviceManagementProviding)?
    private var presenceEnrollmentKey: UUID?
    convenience init(
        route: URL,
        runtime: any SparkRuntimeReading,
        authorizer: any UserPresenceAuthorizing
    ) {
        self.init(
            route: route,
            enrollmentProvider: runtime as? any DeviceManagementProviding,
            authorizer: authorizer
        )
    }

    init(
        route: URL,
        enrollmentProvider: (any DeviceManagementProviding)?,
        authorizer: any UserPresenceAuthorizing
    ) {
        self.route = route
        self.userPresenceAuthorizer = authorizer
        self.presenceEnrollmentProvider = enrollmentProvider
    }

    func submitPresenceAuthorized(
        reason: String,
        submit: @escaping (any UserPresenceProofSigning) async throws -> SparkAPI.Operation
    ) async throws -> SparkAPI.Operation {
        let presence = try await userPresenceAuthorizer.authorize(localizedReason: reason)
        do {
            return try await submit(presence)
        } catch {
            guard (error as? APIError)?.code == "USER_PRESENCE_NOT_REGISTERED" else {
                throw error
            }
            try await enrollPresenceKey()
            let retry = try await userPresenceAuthorizer.authorize(localizedReason: reason)
            return try await submit(retry)
        }
    }

    private func enrollPresenceKey() async throws {
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
                route: route,
                idempotencyKey: key,
                userPresence: presence
            )
            presenceEnrollmentKey = nil
        } catch {
            if Self.isDefinitivePresenceEnrollmentRejection(error) {
                presenceEnrollmentKey = nil
            }
            throw error
        }
    }

    private static func isDefinitivePresenceEnrollmentRejection(_ error: any Error) -> Bool {
        guard let status = (error as? APIError)?.statusCode else { return false }
        return (400...499).contains(status)
    }
}
